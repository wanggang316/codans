import Foundation
import CodansCore
import os.log

/// Central chokepoint for notifications. Every `Candidate` the detector
/// produces flows through `handle(_:)`, which gates against the four
/// settings.json toggles (`inAppEnabled`, `systemEnabled`, `soundEnabled`,
/// `dockBadgeEnabled`), routes the live banner through `OSNotifier`, and
/// updates the Dock badge mirror in lockstep with the inbox.
///
/// The class is intentionally test-friendly: collaborators are protocols /
/// closures, the public `Decision` return value carries enough detail for
/// tests to assert outcomes without scraping mock collaborators, and the
/// settings + authorization snapshot is read at decision time rather than
/// captured at construction so a same-tick toggle flip is honoured.
@MainActor
final class NotificationCoordinator {
  private let inbox: NotificationStore
  private let osNotifier: any OSNotifier
  private let settingsReader: any NotificationSettingsReader
  private let catalog: HierarchyClient
  private let now: @MainActor () -> Date
  private let logger = Logger(
    subsystem: "com.gumpw.codans.notifications",
    category: "coordinator"
  )

  /// Unread count per worktree, maintained alongside `inbox` mutations.
  /// Surfaced for tests; the live "promote notified worktree to top"
  /// behaviour reads the per-call `before` delta directly off
  /// `inbox.entries` rather than this cache so a same-tick mutation
  /// outside the coordinator cannot desync the gate.
  internal private(set) var unreadByWorktree: [WorktreeID: Int] = [:]

  /// Test seam: drop reasons logged on the most recent `handle(_:)` call.
  /// Reset at the top of every `handle` invocation. Production reads only
  /// the `Decision` return value; this exists so a test can assert the
  /// log-emitting code path was exercised without intercepting `os.Logger`.
  internal private(set) var lastDropReasons: [DropReason] = []

  init(
    inbox: NotificationStore,
    osNotifier: any OSNotifier,
    settingsReader: any NotificationSettingsReader,
    catalog: HierarchyClient,
    now: @MainActor @escaping () -> Date = { Date() }
  ) {
    self.inbox = inbox
    self.osNotifier = osNotifier
    self.settingsReader = settingsReader
    self.catalog = catalog
    self.now = now

    // Bootstrap the unread-per-worktree cache from any inbox entries that
    // were rehydrated from disk. Without this, a process restart with
    // persisted unread entries would leave the cache at zero and the
    // promotion logic would never fire until a brand-new notification
    // landed on that worktree.
    for entry in inbox.entries where entry.isUnread {
      unreadByWorktree[entry.source.worktreeID, default: 0] += 1
    }
  }

  /// Every candidate notification passes through here. Returns the decision
  /// so tests can inspect what happened without scraping mock collaborators.
  @discardableResult
  func handle(_ candidate: Candidate) async -> Decision {
    lastDropReasons = []

    if candidate.sourceIsFocused {
      logger.debug("drop sourceIsFocused")
      lastDropReasons.append(.sourceIsFocused)
      return .dropped(reason: .sourceIsFocused)
    }

    let settings = settingsReader.notifications
    let auth = settingsReader.authStatus

    // Inbox path. `inbox.append` may dedup (same paneID+kind within 30 s
    // merges into the prior entry preserving its `readAt`) or evict an
    // unread row when the 500-cap is hit. Both outcomes mean the
    // per-worktree unread count did NOT actually grow on this call, so
    // we read the canonical count from `inbox.entries` before and after
    // the append and report the actual delta. The cache mirrors the
    // post-append truth so the promote logic below sees a faithful
    // 0→N edge rather than an inflated synthetic one.
    //
    // `before` is hoisted out of the `if settings.inAppEnabled` block so
    // the promote branch can gate on the worktree's pre-append unread
    // count. When inbox is disabled, `before` is computed but unused;
    // the promote branch is short-circuited by `didAppend == false`.
    let worktreeID = candidate.entry.source.worktreeID
    let before = unreadCount(inWorktree: worktreeID)
    let didAppend: Bool
    if settings.inAppEnabled {
      inbox.append(candidate.entry)
      let after = unreadCount(inWorktree: worktreeID)
      unreadByWorktree[worktreeID] = after
      didAppend = (after > before)
    } else {
      didAppend = false
      logger.debug("drop inAppDisabled (inbox not appended)")
      lastDropReasons.append(.inAppDisabled)
    }

    // Dock badge path. `recomputeDockBadge` is the single function that
    // honours both `inAppEnabled` and `dockBadgeEnabled`, so we call it
    // unconditionally on every `handle` — defense in depth against any
    // path that mutates inbox state without going through the
    // `dockBadgerTask` mirror or the settings `onChange` subscription.
    // `didBadge` reflects the user-visible truth: the badge changed only
    // when the inbox actually grew AND the dock surface is enabled.
    recomputeDockBadge()
    let didBadge = didAppend && settings.dockBadgeEnabled

    // OS banner path. Independent of `inAppEnabled` by design — the user
    // can run banner-only, inbox-only, both, or neither.
    let didPost: Bool
    let didSound: Bool
    if settings.systemEnabled {
      if auth == .authorized {
        await osNotifier.post(
          candidate.entry,
          playSound: settings.soundEnabled,
          sourceLabel: candidate.bannerSourceLabel
        )
        didPost = true
        didSound = settings.soundEnabled
      } else {
        didPost = false
        didSound = false
        logger.debug("drop authorizationDenied")
        lastDropReasons.append(.authorizationDenied)
      }
    } else {
      didPost = false
      didSound = false
      logger.debug("drop systemDisabled")
      lastDropReasons.append(.systemDisabled)
    }

    // Promote on the 0→N unread edge: a worktree gaining its FIRST unread
    // notification jumps to the top of its parent project's unpinned
    // section. Per-project; pinned worktrees are filtered out by the
    // catalog (HierarchyManager.promoteWorktree silently no-ops on pinned
    // targets — coordinator policy stays simple). Subsequent unreads on
    // the same worktree do NOT retrigger because `before > 0`. The
    // promote is one-shot: the position is not restored when unread drops
    // to zero, but marking all read flips `before` back to 0 so the next
    // unread on that worktree re-promotes.
    let didPromote: Bool
    if didAppend && settings.moveNotifiedWorktreeToTop && before == 0 {
      catalog.promoteWorktree(
        candidate.entry.source.projectID,
        candidate.entry.source.worktreeID,
        .moveToFrontWithinUnpinned
      )
      didPromote = true
    } else {
      didPromote = false
    }

    return .posted(
      inAppAppended: didAppend,
      osBannerPosted: didPost,
      soundPlayed: didSound,
      badgeUpdated: didBadge,
      promoted: didPromote
    )
  }

  /// Recomputes the Dock badge label from the live inbox unread count,
  /// honouring both `inAppEnabled` (no inbox surface → no badge) and
  /// `dockBadgeEnabled` (badge surface explicitly off).
  func recomputeDockBadge() {
    let settings = settingsReader.notifications
    if !settings.inAppEnabled || !settings.dockBadgeEnabled {
      DockBadger.setBadge(0)
    } else {
      DockBadger.setBadge(inbox.unreadCount)
    }
  }

  /// Re-reads the OS authorization status. AppState wires this at app start
  /// and on `applicationDidBecomeActive`. No-op when `settingsReader` is not
  /// the concrete `SettingsStoreReaderAdapter` (tests use the fake reader
  /// and set `authStatus` directly).
  func refreshAuthorizationStatus() async {
    if let adapter = settingsReader as? SettingsStoreReaderAdapter {
      await adapter.refresh()
    }
  }

  /// Emit a one-shot synthetic "Inbox reset" entry when the inbox file
  /// was quarantined on load (forward-version `notifications.json` renamed
  /// to `notifications.json.bak-<ISO>`). Idempotent across launches: the
  /// idempotency marker (`~/.config/codans/notifications.quarantine-shown`)
  /// records the backup-file basename of the last quarantine we showed; if
  /// the current backup matches, return without emitting.
  ///
  /// Routed through `handle(_:)` so the standard gates (`inAppEnabled`,
  /// `systemEnabled`, …) apply. The synthetic entry uses zero-UUID
  /// hierarchy IDs so clicking the row in the bell popover falls through
  /// `RootFeature.focusHierarchyPath`'s dead-target fallback rather than
  /// trying to navigate to a fake pane.
  ///
  /// The marker write is unconditional — even when the chokepoint gate
  /// (`inAppEnabled = false` etc.) drops the synthetic entry, we still
  /// record that this quarantine event was processed. The user's
  /// "no banners right now" intent should not cause the quarantine notice
  /// to keep retrying on every relaunch.
  func emitQuarantineNotice(
    backupURL: URL,
    markerURL: URL = AppDirectories.configDirectory()
      .appendingPathComponent("notifications.quarantine-shown")
  ) async {
    let backupBasename = backupURL.lastPathComponent

    // Idempotency: if a marker file already records this exact backup
    // basename, the toast has already been shown on a prior launch — skip.
    if let existing = try? String(contentsOf: markerURL, encoding: .utf8),
      existing == backupBasename
    {
      return
    }

    let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    let synthetic = InboxEntry(
      kind: .taskFinished,
      title: "Inbox reset",
      body:
        "Your inbox was reset because notifications.json had an unsupported version. "
        + "Backup saved as \(backupBasename).",
      source: InboxEntry.SourcePath(
        projectID: ProjectID(raw: zeroUUID),
        worktreeID: WorktreeID(raw: zeroUUID),
        tabID: TabID(raw: zeroUUID),
        paneID: PaneID(raw: zeroUUID)
      )
    )
    let candidate = NotificationCoordinator.Candidate(
      entry: synthetic, sourceIsFocused: false
    )
    _ = await self.handle(candidate)

    // Write the marker. Ensure the parent directory exists first — the
    // inbox file's own creator (`InboxFile`) normally creates it, but a
    // test (or a fresh boot with quarantine before any inbox write) may
    // race ahead of that. Failures here only affect re-fire idempotency
    // on the next launch; the toast itself already surfaced.
    do {
      let parent = markerURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true
      )
      try Data(backupBasename.utf8).write(to: markerURL, options: .atomic)
      logger.info(
        "emitted Inbox reset toast for backup=\(backupBasename, privacy: .public)"
      )
    } catch {
      let path = markerURL.path
      let desc = String(describing: error)
      logger.error(
        "failed to write quarantine marker at \(path, privacy: .public): \(desc, privacy: .public)"
      )
    }
  }

  // MARK: - Internals

  /// Per-worktree unread count read off the canonical inbox. Called twice
  /// per `handle` invocation to compute the actual append delta after
  /// `inbox.append` (which may dedup within 30 s or evict an unread row on
  /// the 500-cap eviction). O(N) over `inbox.entries`; N is capped at 500
  /// by `InboxStorage.cap`, so the per-append cost is well inside the
  /// MainActor budget.
  private func unreadCount(inWorktree worktreeID: WorktreeID) -> Int {
    inbox.entries.reduce(0) { acc, entry in
      acc + (entry.source.worktreeID == worktreeID && entry.isUnread ? 1 : 0)
    }
  }

  // MARK: - Nested types

  /// A candidate notification produced by `NotificationDetector`. The
  /// `sourceIsFocused` flag is pre-computed by the detector because it
  /// already has to walk the catalog to enrich the title; passing it
  /// through avoids a second walk inside the coordinator.
  struct Candidate: Equatable, Sendable {
    let entry: InboxEntry
    /// True iff the source pane equals the user's globally-focused pane.
    let sourceIsFocused: Bool
    /// `<project> · <worktree>` resolved by the detector against the live
    /// catalog. Appended on its own line after the OS banner body; inbox
    /// surfaces don't read this field. Nil when the source cache fallback
    /// path was taken (live catalog lost both names).
    let bannerSourceLabel: String?

    init(entry: InboxEntry, sourceIsFocused: Bool, bannerSourceLabel: String? = nil) {
      self.entry = entry
      self.sourceIsFocused = sourceIsFocused
      self.bannerSourceLabel = bannerSourceLabel
    }
  }

  /// Outcome of `handle(_:)`. `.posted` always carries the full bool tuple
  /// so a single decision can describe asymmetric outcomes (e.g. "appended
  /// to the inbox but the system banner was suppressed because the user
  /// turned off `systemEnabled`"). `.dropped` is reserved for the single
  /// gate that suppresses every surface — the source pane being focused.
  enum Decision: Equatable, Sendable {
    case posted(
      inAppAppended: Bool,
      osBannerPosted: Bool,
      soundPlayed: Bool,
      badgeUpdated: Bool,
      promoted: Bool
    )
    case dropped(reason: DropReason)
  }

  /// `paneMuted`, `commandFinishedDisabled`, `commandFinishedShort`,
  /// `commandCancelled`, `userTypingRecently` are reserved for the
  /// interpreter log line — the coordinator itself does not emit them today.
  enum DropReason: String, Equatable, Sendable {
    case sourceIsFocused
    case inAppDisabled
    case systemDisabled
    case paneMuted
    case commandFinishedDisabled
    case commandFinishedShort
    case commandCancelled
    case userTypingRecently
    case authorizationDenied
  }
}
