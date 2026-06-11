import AppKit
import Foundation
import OSLog
import CodansCore

private let detectorLogger = Logger(
  subsystem: "com.gumpw.codans.notifications", category: "detector"
)

/// Translates the runtime's structured `TerminalEvent` stream into
/// `InboxEntry` rows and routes them to `NotificationStore` plus a
/// macOS banner (when the user is not already looking at the source).
///
/// This is *not* a stdout regex scanner — it consumes only the typed
/// events libghostty + the engine already publish: OSC 9 desktop
/// notifications, terminal bell, OSC 133 `commandFinished`,
/// `paneExited`, `paneCrashed`, and `paneIdle`. Tools that don't emit
/// any of these are silently uncovered; this is a documented v1 trade-off.
///
/// `RootFeature.engineEventReceived` calls `handle(_:)` for every
/// runtime event so the detector lives downstream of the existing
/// single-consumer event loop and does not need its own subscription.
@MainActor
public final class NotificationDetector {
  private let store: NotificationStore
  private let coordinator: NotificationCoordinator
  private let catalogSnapshot: @MainActor () -> Catalog
  private let lastFocusedPane: @MainActor (TabID) -> PaneID?
  private let isAppFrontmost: @MainActor () -> Bool
  /// Side-channel keystroke tracker. Snapshotted once per event into the
  /// interpreter's `Context.lastUserKeystrokeAt` so the 1-second
  /// `userTypingRecently` suppression can actually fire on real input.
  private let tracker: PaneKeyboardActivityTracker
  /// Settings reader: the interpreter's command-finished branch reads
  /// `commandFinishedEnabled` and `commandFinishedThresholdSec` from the
  /// per-event Context, so the detector folds the live snapshot in here
  /// every call rather than capturing values at construction.
  private let settingsReader: any NotificationSettingsReader
  /// Fired with the source Project of every emitted notification, before
  /// the inbox is appended. The sidebar's "active first" sort uses this
  /// to bump `Project.lastActiveAt`. Optional so call sites without a
  /// hierarchy manager wired (tests, previews) can drop it.
  private let onProjectActivity: (@MainActor (ProjectID) -> Void)?

  /// Panes that have produced any `paneOutput` since launch (or since the
  /// last time their child exited). Gates `paneIdle` so a freshly spawned
  /// pane that has never produced output cannot fire a `taskFinished`.
  private var hasProducedOutput: Set<PaneID> = []

  /// Cached `(projectID, worktreeID, tabID, paneID)` per pane so a
  /// terminal `paneExited` / `paneCrashed` event can still produce a
  /// notification even when `RootFeature`'s parallel event consumer
  /// has already called `closePane` and removed the pane from the
  /// live catalog. Updated whenever a live catalog walk succeeds;
  /// cleared on the pane's lifecycle teardown events.
  private var paneSourceCache: [PaneID: InboxEntry.SourcePath] = [:]

  init(
    store: NotificationStore,
    coordinator: NotificationCoordinator,
    tracker: PaneKeyboardActivityTracker,
    settingsReader: any NotificationSettingsReader,
    catalogSnapshot: @escaping @MainActor () -> Catalog,
    lastFocusedPane: @escaping @MainActor (TabID) -> PaneID?,
    isAppFrontmost: @escaping @MainActor () -> Bool = { NSApp.isActive },
    onProjectActivity: (@MainActor (ProjectID) -> Void)? = nil
  ) {
    self.store = store
    self.coordinator = coordinator
    self.tracker = tracker
    self.settingsReader = settingsReader
    self.catalogSnapshot = catalogSnapshot
    self.lastFocusedPane = lastFocusedPane
    self.isAppFrontmost = isAppFrontmost
    self.onProjectActivity = onProjectActivity
  }

  /// The single globally focused pane — the pane the user is *actually*
  /// looking at right now. Composed from the active project → active
  /// worktree → active tab → that tab's last-focused split, and only
  /// when the app itself is frontmost. There is at most one such pane
  /// at any moment; `nil` means "the user is not looking at any pane"
  /// (app backgrounded, no selection, sidebar focus, etc.).
  ///
  /// Notifications whose source matches this pane are dropped entirely:
  /// no inbox row, no banner, no badge — the user is already eyeballing
  /// the in-pane output.
  private func globallyFocusedPane() -> PaneID? {
    guard isAppFrontmost() else { return nil }
    let catalog = catalogSnapshot()
    guard let activeProjectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == activeProjectID }),
      let worktreeID = project.selectedWorktreeID,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let tabID = worktree.selectedTabID
    else { return nil }
    return lastFocusedPane(tabID)
  }

  /// Single entry point. Called for every `TerminalEvent` the runtime
  /// emits. The shared interpretation table lives in
  /// `CodansCore.PaneAttentionInterpreter`; this method orchestrates:
  /// catalog walk → SourcePath, mute label check, then hands a
  /// `Candidate` to `NotificationCoordinator`. The coordinator owns
  /// inbox append, banner posting, dock badge, and the focused-pane drop.
  public func handle(_ event: TerminalEvent) async {
    let notifSettings = settingsReader.notifications
    let context = PaneAttentionInterpreter.Context(
      hasProducedOutput: hasProducedOutput,
      lastUserKeystrokeAt: tracker.snapshot(),
      now: Date(),
      commandFinishedEnabled: notifSettings.commandFinishedEnabled,
      commandFinishedThresholdSec: notifSettings.commandFinishedThresholdSec
    )
    let step = PaneAttentionInterpreter.interpret(event, context: context)

    if let drop = step.drop {
      detectorLogger.debug(
        "interpreter drop reason=\(drop.rawValue, privacy: .public)"
      )
    }

    switch step.outputFlag {
    case .markProduced(let paneID):
      hasProducedOutput.insert(paneID)
      // Refresh the source-path cache while the pane is still live in
      // the catalog. By the time a future paneExited event flows through
      // here, RootFeature's parallel consumer may have removed the pane;
      // the cache means we still know where it lived.
      _ = liveResolve(paneID: paneID)
    case .clearProduced(let paneID):
      hasProducedOutput.remove(paneID)
      // Same upper-bound guarantee for the keystroke map: teardown events
      // purge so the map's size stays bounded by "open panes plus a
      // handful in-flight" rather than monotonically growing.
      tracker.purge(paneID)
    // Don't drop cache here — `emit` for the same teardown event still
    // needs to look up the source path. Cache is dropped at the end of
    // `emit` once we've actually used it.
    case .unchanged:
      break
    }

    guard let cue = step.cue else { return }
    await emit(cue, isTeardown: step.outputFlag.isTeardown)
  }

  private func emit(_ cue: PaneAttentionInterpreter.Cue, isTeardown: Bool) async {
    guard let resolved = resolve(paneID: cue.paneID) else { return }
    if resolved.muted { return }

    // Pre-compute the focused-pane comparison once so the coordinator does
    // not have to walk the catalog a second time. The coordinator owns the
    // "drop when source is focused" decision; this just hands it the
    // verdict. There is at most one globally-focused pane at any time
    // (see `globallyFocusedPane` doc), so this is not symmetric with the
    // per-tab last-focused behaviour: a notification fired from a
    // non-active tab's last-focused split *will* notify, because by
    // definition the user isn't looking at it.
    let sourceIsFocused = resolved.source.paneID == globallyFocusedPane()

    // HAN-78: title stays clean; the source breadcrumb
    // (`<project> · <worktree>`) is attached as `bannerSourceLabel` and
    // appended to the OS banner body by `UserNotificationsOSNotifier`.
    // The inbox popover already shows the same breadcrumb on the right
    // of each row, so we deliberately keep `entry.body` untouched.
    let entry = InboxEntry(
      kind: cue.kind,
      title: cue.title,
      body: cue.body,
      source: resolved.source
    )
    let bannerSourceLabel = sourceLabel(
      projectLabel: resolved.projectLabel,
      worktreeLabel: resolved.worktreeLabel
    )
    // Activity bump for the sidebar's "active first" sort fires
    // before the coordinator dispatch: `lastActiveAt` reflects "a
    // notification fired", independent of whether the coordinator
    // ultimately surfaces it or any of the toggles suppress it.
    onProjectActivity?(resolved.source.projectID)

    // Single chokepoint: the coordinator gates against settings, updates
    // the inbox + dock badge, and routes the banner. The detector no
    // longer touches `NotificationStore.append` or `OSNotifier.post`
    // directly.
    await coordinator.handle(
      NotificationCoordinator.Candidate(
        entry: entry,
        sourceIsFocused: sourceIsFocused,
        bannerSourceLabel: bannerSourceLabel
      )
    )

    // Drop the cache only after the entry has been emitted. A teardown
    // event (paneExited / paneCrashed / paneClosedByTab) still needs
    // the cached source path to resolve, but no future event for this
    // pane id will ever arrive again — clean up.
    if isTeardown {
      paneSourceCache.removeValue(forKey: cue.paneID)
    }
  }

  // MARK: - Helpers

  /// Resolve `paneID` to source path + mute state + worktree label +
  /// project label. Tries the live catalog first; falls back to
  /// `paneSourceCache` when the pane has already been removed from the
  /// catalog (typical on `paneExited`: `RootFeature.paneLifecycleExited`
  /// may have closed it before this consumer runs). Returns nil only when
  /// both the live catalog and the cache have nothing — meaning the pane
  /// never had any prior catalog presence in this process. Cache fallback
  /// path loses worktree/project labels + mute info; that's an acceptable
  /// trade for not silently swallowing the final teardown notification.
  private func resolve(paneID: PaneID) -> Resolved? {
    if let live = liveResolve(paneID: paneID) {
      return live
    }
    if let cached = paneSourceCache[paneID] {
      return Resolved(source: cached, muted: false, worktreeLabel: nil, projectLabel: nil)
    }
    return nil
  }

  /// Live-catalog resolve. On success, refreshes `paneSourceCache` so
  /// later teardown events still have a valid source after the pane
  /// has been removed from the catalog.
  @discardableResult
  private func liveResolve(paneID: PaneID) -> Resolved? {
    let catalog = catalogSnapshot()
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          guard let pane = tab.panes.first(where: { $0.id == paneID }) else { continue }
          let source = InboxEntry.SourcePath(
            projectID: project.id,
            worktreeID: worktree.id,
            tabID: tab.id,
            paneID: pane.id
          )
          paneSourceCache[paneID] = source
          let worktreeLabel = worktree.name.isEmpty ? nil : worktree.name
          let projectLabel = project.name.isEmpty ? nil : project.name
          return Resolved(
            source: source,
            muted: pane.labels.contains(InboxLabels.muted),
            worktreeLabel: worktreeLabel,
            projectLabel: projectLabel
          )
        }
      }
    }
    return nil
  }

  /// Banner source label: `【<project>·<worktree>】` (project first, the
  /// stable axis; worktree second, the volatile one). Full-width brackets
  /// and a no-space `·` mirror the spec Gump gave for HAN-78. Returns nil
  /// when both labels are missing so the OS banner falls back to a
  /// body-only rendering rather than a dangling pair of empty brackets.
  private func sourceLabel(projectLabel: String?, worktreeLabel: String?) -> String? {
    let parts = [projectLabel, worktreeLabel].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    return "【\(parts.joined(separator: "·"))】"
  }

  private struct Resolved {
    let source: InboxEntry.SourcePath
    let muted: Bool
    let worktreeLabel: String?
    let projectLabel: String?
  }
}
