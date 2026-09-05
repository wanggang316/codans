import AppKit
import CodansCore
import CodansIPC
import Combine
import ComposableArchitecture
import GhosttyKit
import SwiftUI
@preconcurrency import UserNotifications
import os

@main
struct CodansApp: App {
  init() {
    // SwiftUI evaluates view bodies — and therefore any `@Dependency(...)`
    // captured in `@Observable` view-models or `Commands` structs — before
    // the scene's `.task { appState.bringUp() }` ever runs. When the app is
    // loaded as the XCTest host, every unset `DependencyKey` falls through
    // to `testValue`, which for our clients (and TCA's built-ins) records
    // an `Issue` from any detached task that touches them. Register the
    // pure-Foundation built-ins here so a view body resolving `\.date` or
    // `\.uuid` before `bringUp()` gets a sane default; engine-dependent
    // clients are still wired inside `bringUp` where `engine` exists.
    prepareDependencies {
      $0.date = .init { Date() }
      $0.continuousClock = ContinuousClock()
      $0.suspendingClock = SuspendingClock()
      $0.uuid = .init { UUID() }
      // GitHubClient + GitServiceClient have no engine/state dependency, so
      // wire them here too — both are touched by background tasks (PR
      // batch fetch, sidebar status monitor) that the running host app spins
      // up before `bringUp()` reaches its own `prepareDependencies` block.
      $0.gitHub = .live()
      $0.gitService = .live()
    }

    // Install the Sentry crash handler before SwiftUI renders anything,
    // so view-body crashes are still captured. Reads settings directly
    // from disk because SettingsStore is constructed later in
    // AppState.bringUp(); the read is cheap and degrades to defaults on
    // any failure. DEBUG builds and users who opted out short-circuit
    // inside `bootstrap`.
    CrashReporting.bootstrap(
      settings: CrashReporting.loadSettingsForBootstrap(),
      infoDictionary: Bundle.main.infoDictionary ?? [:]
    )
  }

  /// Single long-lived runtime stack. `@State` keeps this alive across the
  /// scene lifecycle without re-creating on re-render.
  @State private var appState = AppState()
  /// 0014: scene-wide ⌘ modifier observer, injected via `.environment`
  /// so any view (currently: the status-bar PR form) can swap hints when
  /// the user holds ⌘. The class self-installs its NSEvent monitor at
  /// `init` and tears down in `deinit`, so no explicit lifecycle calls
  /// are needed here.
  @State private var commandKeyObserver = CommandKeyObserver()
  /// Tracks whether the sidebar list holds first-responder. `MainWindowCommands` reads it
  /// to gate destructive worktree chords (`⌘⌫` / `⌘⇧⌫`) so they only fire while the user
  /// is on the sidebar; when focus is in a Ghostty terminal pane the menu items are
  /// disabled and the chord falls through to the terminal.
  @State private var sidebarFocusObserver = SidebarFocusObserver()
  /// `SwiftUI.App` gives us no `applicationWillTerminate` hook on its own;
  /// the adaptor bridges AppKit's termination callback so we can flush
  /// debounced writes from `SettingsStore` before the process exits.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    // Single-instance main window. `Window(id:)` (vs. the previous
    // `WindowGroup`) ensures re-activating the dock icon brings the
    // existing window forward instead of spawning a duplicate, and the
    // system menu does not synthesize a "New Window" item that would let
    // users create extras out-of-band.
    Window("Codans", id: CodansApp.mainWindowID) {
      AppAppearanceView(settingsStore: appState.settingsStore) {
        if let store = appState.store, appState.terminalEngine != nil {
          ContentView(
            store: store,
            hierarchyManager: appState.hierarchyManager,
            settingsStore: appState.settingsStore,
            worktreeStatusMonitor: appState.worktreeStatusMonitor,
            worktreeLocalDiffMonitor: appState.worktreeLocalDiffMonitor,
            notificationRollup: appState.notificationRollup,
            notificationStore: appState.notificationStore,
            osNotifier: appState.osNotifier,
            agentStateStore: appState.agentStateStore
          )
          .frame(minWidth: 800, minHeight: 600)
          .environment(appState.agentInstallation)
          .environment(commandKeyObserver)
          .environment(\.resolvedShortcuts, appState.shortcutsStore.resolved)
          // Redirect ⌘W (claimed by AppKit's File ▸ Close) away from tearing
          // down the single main window. ⌘W escalates pane → tab → window:
          // close the focused pane/tab while one exists; only when the current
          // worktree has no active tab left does ⌘W fall through and close the
          // window. The closure returns whether it closed something so the
          // window-delegate knows to veto (true) or allow (false) the close.
          // See MainWindowCloseInterceptor.
          .background(
            MainWindowCloseRedirector(
              onCloseChord: {
                // Resolve the worktree from the same `state.selection` that
                // `closeActiveTabForCurrentWorktree` acts on — it already applies
                // `currentSelection`'s `selectedProjectID == nil` fallback (a
                // restored project whose `selectedWorktreeID` is set but with no
                // top-level selected project). Reading `catalog.selectedProjectID`
                // here would miss that state and wrongly let ⌘W close the window.
                let selection = store.state.selection
                let catalog = appState.hierarchyManager.catalog
                guard
                  let projectID = selection.projectID,
                  let worktreeID = selection.worktreeID,
                  let worktree = catalog.projects.first(where: { $0.id == projectID })?
                    .worktrees.first(where: { $0.id == worktreeID }),
                  let activeTabID = worktree.selectedTabID,
                  worktree.tabs.contains(where: { $0.id == activeTabID })
                else {
                  return false  // nothing to close → let ⌘W close the window
                }
                store.send(.closeActiveTabForCurrentWorktree)
                return true  // closed a pane/tab → keep the window open
              }
            )
          )
        } else {
          // Initial loading state while appState.bringUp runs. The launch
          // skeleton mirrors the real two-column NavigationSplitView chrome
          // (ghost sidebar + detail caption + toolbar) so the window reads
          // as "our app, loading" instead of a frozen placeholder. It is
          // intentionally cosmetic — bringUp is kicked off from `.task`
          // below, and the idempotency guard (`store == nil` check inside
          // bringUp) is load-bearing because SwiftUI re-runs `.task` on
          // scene reattach.
          LaunchSkeletonView()
            .frame(minWidth: 800, minHeight: 600)
            .task {
              appDelegate.appState = appState
              appState.openSettingsWindowAction = {
                openWindow(id: CodansApp.settingsWindowID)
              }
              appState.bringUp()
            }
        }
      }
      // Drop this window's "Codans" entry from the Window menu's auto list.
      .background(ExcludeFromWindowsMenu())
    }
    .windowStyle(.titleBar)
    // Unified toolbar style lets the NavigationSplitView sidebar column's
    // material extend up under the traffic lights, matching Finder / Xcode.
    // Without this, the Ghostty-stained NSWindow background shows through
    // the titlebar area and the first List row visually overlaps with the
    // window controls.
    .windowToolbarStyle(.unified)
    .commands {
      // `MainWindowCommands` is rendered unconditionally and reads
      // `appState.store` lazily. Wrapping the call in `if let store = appState.store { … }`
      // resolves once at scene build (when `bringUp()` has not yet run and the store is
      // nil); SwiftUI's `Commands` builder does not subsequently re-add the dropped commands
      // when the store materialises, leaving the entire File menu absent and unbinding ⌘O /
      // ⌘P / ⌘T / etc. for the rest of the session.
      //
      // We also intentionally do NOT add `CommandGroup(replacing: .newItem) {}` to suppress
      // ⌘N "New Window": with `Window(id:)` AppKit no longer synthesizes that item, and the
      // empty-replacing block has the surprising side effect of wiping out every
      // `CommandGroup(after: .newItem)` content from `MainWindowCommands`.
      MainWindowCommands(
        store: { appState.store },
        shortcuts: appState.shortcutsStore.resolved,
        sidebarFocus: sidebarFocusObserver,
        settingsStore: appState.settingsStore,
        hierarchyManager: appState.hierarchyManager
      )
      CommandGroup(replacing: .appSettings) {
        // Chord routes through the registry so a user override in Settings → Shortcuts
        // rebinds the menu item without restart. Default remains the AppKit-conventional ⌘,.
        Button("Settings…") {
          openWindow(id: CodansApp.settingsWindowID)
        }
        .appKeyboardShortcut(.openSettings, in: appState.shortcutsStore.resolved)
      }
    }

    Window("Settings", id: CodansApp.settingsWindowID) {
      AppAppearanceView(settingsStore: appState.settingsStore) {
        if let store = appState.settingsWindowStore {
          SettingsWindowView(
            store: store,
            settingsStore: appState.settingsStore,
            shortcutsStore: appState.shortcutsStore,
            sessionCoordinator: appState.sessionCoordinator,
            onForgetAllSessions: {
              appState.forgetAllPersistedSessions()
            }
          )
          .environment(appState.hierarchyManager)
          .environment(appState.settingsStore)
          .environment(appState.developerPaneDependencies)
          .environment(appState.osNotifier)
          .environment(appState.agentInstallation)
          .environment(commandKeyObserver)
          .environment(\.resolvedShortcuts, appState.shortcutsStore.resolved)
        } else {
          // Settings window can be opened before AppState.bringUp completes (rare but
          // possible during launch). Render a transient placeholder; SwiftUI will
          // re-evaluate once the store lands.
          ProgressView().frame(minWidth: 750, minHeight: 500)
        }
      }
      .background(SettingsWindowTag())
      // Drop this window's "Settings" entry from the Window menu's auto list.
      .background(ExcludeFromWindowsMenu())
    }
    .defaultSize(width: 750, height: 500)
    .windowResizability(.contentMinSize)
  }

  /// Scene id for the Settings `Window`. Referenced from the app-menu Settings… command and
  /// from `SettingsWindowPresenter` overrides below.
  static let settingsWindowID = "settings"

  /// Scene id for the single main window.
  static let mainWindowID = "main"
}

/// AppKit delegate that flushes debounced writes on graceful termination
/// and gates ⌘Q with a confirmation when running terminal sessions exist.
/// The weak reference is set from the scene's `.task` after `AppState` has
/// been constructed — before that, `applicationWillTerminate` is a no-op,
/// which is fine because nothing has been written yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  weak var appState: AppState?

  /// Re-entrancy guard. A first `applicationShouldTerminate` that
  /// chooses a disposition returns `.terminateLater` and spawns the (async)
  /// snapshot/detach work in a detached `@MainActor` Task. AppKit keeps the
  /// process alive pending the `reply`, but a fresh user-initiated quit
  /// (rapid double ⌘Q) — or AppKit re-issuing terminate — can re-enter this
  /// callback before that reply lands. Without a cross-call latch the second
  /// entry would spawn a SECOND `detachAllForQuit`: a duplicate snapshot loop
  /// and a duplicate `sessions.json` persist racing the first. The flag is set
  /// the instant the first disposition is dispatched and is never cleared
  /// (the only transition out of "disposition in progress" is process exit),
  /// so every subsequent terminate request is a clean no-op that simply
  /// re-returns `.terminateLater` and waits on the original reply.
  private var dispositionInProgress = false

  override init() {
    super.init()
    // Wire up macOS notification banner click delegation. Without this, the
    // taps on banners are silently ignored — clicking would activate the app
    // (default behaviour) but our deeplink would never be parsed.
    UNUserNotificationCenter.current().delegate = self

    // Advertise that focused responders can hand out plain-text selections
    // through the macOS services system. Third-party text utilities
    // (translators, dictionaries, "lookup-on-hover" tools) poll this
    // registration to decide whether to query the frontmost app; without
    // it, the system never asks our terminal surface for its selection
    // even though the surface implements `NSServicesMenuRequestor`.
    NSApplication.shared.registerServicesMenuSendTypes(
      [.string],
      returnTypes: []
    )
  }

  nonisolated func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated {
      appState?.flushAllPersistedState()
    }
  }

  /// Gates `cmd-Q` so the daemon-disposition decision can run before AppKit tears the
  /// process down. The user's `QuitConfirmation` setting decides whether to surface the
  /// quit confirmation dialog at all; the orthogonal `QuitAction` setting decides what
  /// the no-dialog branch applies (and which button is default-focused when the dialog
  /// IS shown).
  ///
  /// Returns `.terminateLater` for keepRunning / snapshot: the daemon-disposition
  /// work (`detachAllForQuit`) is now `async` — the `.snapshot` action awaits each
  /// pane's daemon writing its `.snap` and closing — so we defer the actual
  /// termination until that work finishes (or its bounded ceiling elapses) and
  /// then `reply(toApplicationShouldTerminate: true)`. The subsequent `willTerminate`
  /// hook still fires afterwards so the remaining persisted-state flushes run.
  /// `.cancel` aborts the quit entirely and is unaffected by the snapshot path.
  nonisolated func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
      // A disposition (snapshot/detach) is already in flight from a
      // prior terminate. Do NOT re-run it — that would double-dispatch the
      // snapshot loop and the `sessions.json` persist. Re-return `.terminateLater`
      // so AppKit keeps waiting on the original `reply`; no dialog, no second pass.
      guard !dispositionInProgress else { return .terminateLater }
      guard let appState else { return .terminateNow }
      let lifecycle = appState.sessionLifecycle
      let activePanes = lifecycle?.liveZmxClientCount ?? 0

      let confirmation = appState.settingsStore.settings.general.quitConfirmation
      let action = appState.settingsStore.settings.general.quitAction

      let shouldAsk: Bool
      switch confirmation {
      case .never: shouldAsk = false
      case .always: shouldAsk = true
      case .auto: shouldAsk = activePanes > 0
      }

      if !shouldAsk {
        // No dialog — apply the configured action directly. `detachAllForQuit` is a
        // no-op when there are no live clients, so skipping it for activePanes == 0
        // is purely an optimisation; the explicit guard keeps the no-panes path cheap.
        guard activePanes > 0, let lifecycle else { return .terminateNow }
        return runDetachThenTerminate(lifecycle, action: action, sender: sender)
      }

      let choice = QuitConfirmationDialog.present(
        paneCount: activePanes,
        defaultAction: action
      )
      switch choice {
      case .keepRunning:
        guard let lifecycle else { return .terminateNow }
        return runDetachThenTerminate(lifecycle, action: .keepRunning, sender: sender)
      case .snapshot:
        guard let lifecycle else { return .terminateNow }
        return runDetachThenTerminate(lifecycle, action: .snapshot, sender: sender)
      case .cancel:
        return .terminateCancel
      }
    }
  }

  /// Drive the now-`async` `detachAllForQuit` from the synchronous
  /// `applicationShouldTerminate` callback: spawn a `@MainActor` task that runs
  /// the disposition work, then `reply(toApplicationShouldTerminate: true)`, and
  /// return `.terminateLater` so AppKit keeps the process alive until that reply.
  ///
  /// The wait is bounded two ways so quit can never hang on a wedged daemon:
  /// `detachAllForQuit(.snapshot)` itself is bounded by the per-pane snapshot
  /// timeout, and an outer ceiling races the disposition work against a sleep —
  /// whichever finishes first replies. `reply` is sent exactly once (the
  /// `replied` guard) so a late completion after the ceiling cannot double-reply.
  ///
  /// Instance method (not `static`) so it owns the single write of the
  /// `dispositionInProgress` latch: the flag is set here, synchronously, before
  /// `.terminateLater` is returned, so a re-entrant `applicationShouldTerminate`
  /// (rapid double ⌘Q) sees it and short-circuits without a second disposition.
  @MainActor
  private func runDetachThenTerminate(
    _ lifecycle: SessionLifecycle,
    action: QuitAction,
    sender: NSApplication
  ) -> NSApplication.TerminateReply {
    // Latch before dispatching so any re-entrant terminate is a no-op.
    dispositionInProgress = true
    // Hard ceiling on the total quit wait. `detachAllForQuit` is already
    // bounded by the per-pane timeout × concurrency-window factor; this is a
    // belt-and-suspenders cap so an unforeseen wedge inside the disposition
    // work can never keep the app from exiting.
    let ceiling: Duration = .seconds(20)
    Task { @MainActor in
      var replied = false
      func replyOnce() {
        guard !replied else { return }
        replied = true
        sender.reply(toApplicationShouldTerminate: true)
      }
      // Run the disposition work as a child task so the watchdog below can
      // cancel it once the ceiling fires; both children stay on the main actor
      // so the shared `replied` flag needs no extra synchronisation.
      let work = Task { @MainActor in
        await lifecycle.detachAllForQuit(action: action)
      }
      let watchdog = Task { @MainActor in
        try? await Task.sleep(for: ceiling)
        // Ceiling hit before the disposition work finished: stop waiting and
        // let the app exit. `Task.sleep` throws `CancellationError` if the
        // work finished first, in which case this branch is skipped.
        guard !Task.isCancelled else { return }
        work.cancel()
        replyOnce()
      }
      // Await the disposition work; whichever lands first (it or the ceiling)
      // calls `replyOnce`, then we cancel the watchdog so it does not linger.
      await work.value
      watchdog.cancel()
      replyOnce()
    }
    return .terminateLater
  }

  /// Handles a banner click. Parses the deeplink the OSNotifier embedded
  /// in `userInfo["deeplink"]` and dispatches `RootFeature.focusHierarchyPath`
  /// against the live root store.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let deeplink = userInfo["deeplink"] as? String
    let source =
      deeplink
      .flatMap(URL.init(string:))
      .flatMap(Self.parseDeeplink(_:))
    completionHandler()
    Task { @MainActor in
      guard let source else { return }
      appState?.store?.send(.focusHierarchyPath(source))
    }
  }

  /// Allow banners to fire while the app is foreground (default macOS
  /// behaviour suppresses them). The detector already gates banner posting
  /// on "either app not frontmost OR pane not focused", so by the time we
  /// reach this delegate we already know the user can't see the source.
  /// `.sound` is included so the per-notification `content.sound` set by
  /// `OSNotifier.post` actually plays while the app is foregrounded —
  /// without it macOS silences sound for the foregrounded delivery path
  /// even when authorization was granted with `.sound`.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  /// `codans://focus?project=...&worktree=...&tab=...&pane=...`
  /// → `(projectID, worktreeID, tabID, paneID)`.
  nonisolated static func parseDeeplink(_ url: URL) -> InboxEntry.SourcePath? {
    guard url.scheme == "codans", url.host == "focus" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let items = Dictionary(
      uniqueKeysWithValues: components?.queryItems?.compactMap { item -> (String, String)? in
        guard let value = item.value else { return nil }
        return (item.name, value)
      } ?? []
    )
    guard let projectStr = items["project"], let projectUUID = UUID(uuidString: projectStr),
      let worktreeStr = items["worktree"], let worktreeUUID = UUID(uuidString: worktreeStr),
      let tabStr = items["tab"], let tabUUID = UUID(uuidString: tabStr),
      let paneStr = items["pane"], let paneUUID = UUID(uuidString: paneStr)
    else { return nil }
    return InboxEntry.SourcePath(
      projectID: ProjectID(raw: projectUUID),
      worktreeID: WorktreeID(raw: worktreeUUID),
      tabID: TabID(raw: tabUUID),
      paneID: PaneID(raw: paneUUID)
    )
  }

  /// `false` keeps the app running in the dock when ⌘W closes the main
  /// window — codans is a long-lived terminal host and an inadvertent
  /// close should not tear down running panes. Re-clicking the dock icon
  /// (or `open -a codans`) re-shows the window.
  nonisolated func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

}

/// Holds the shell-wide runtime objects. `AppState` lives for the duration
/// of the app; `bringUp()` constructs the full stack (including optional
/// `GhosttyRuntime` and the `SocketServer` IPC stack) and assembles the
/// TCA `Store` with live clients. Before `bringUp()` runs, `store` and
/// `terminalEngine` are nil — the app renders a loading placeholder.
@MainActor
@Observable
final class AppState {
  let hierarchyManager: HierarchyManager
  let settingsStore: SettingsStore
  let shortcutsStore: ShortcutsStore
  /// Which coding-agent CLIs are present on this Mac. App-scoped (not owned
  /// by the Settings pane) because two surfaces read it — the Agents pane
  /// greys out missing agents, and the worktree toolbar's Agents menu hides
  /// them — and they must not disagree.
  let agentInstallation = AgentInstallationStore()
  /// One-shot authorization + completion fan-out for panel-injected handoff
  /// requests. Shared by the `handoff.*` IPC handler (claims / publishes)
  /// and the in-app Hand Off panel (registers / observes).
  let handoffRegistry = HandoffRequestRegistry()
  /// Notifications inbox owner; survives the full app lifetime so the
  /// debounced JSON write to `~/.config/codans/notifications.json` and
  /// the in-memory unread state outlive any individual scene transition.
  let notificationStore: NotificationStore
  /// Per-level roll-up derivation; views read `notificationRollup.current`
  /// to render indicators. Created in `bringUp` once `hierarchyManager`
  /// can be queried for focus state.
  private(set) var notificationRollup: RollupIndexProvider?
  /// Drains the engine's TerminalEvent stream into `notificationDetector`.
  /// Held so `flushAllPersistedState` / app shutdown can cancel it cleanly.
  @ObservationIgnored private var notificationDetectorTask: Task<Void, Never>?
  /// Mirrors `notificationStore.unreadCount` onto the macOS Dock tile badge
  /// via `withObservationTracking` re-registration.
  @ObservationIgnored private var dockBadgerTask: Task<Void, Never>?
  /// Re-marks unread entries as read whenever the user focuses the
  /// pane they belong to. Observes catalog focus state via Observation
  /// re-registration; held so shutdown can cancel cleanly.
  @ObservationIgnored private var focusReadMarkerTask: Task<Void, Never>?
  /// Marks orphaned unread entries (whose source pane no longer exists in
  /// the catalog) as read. Observes the catalog's pane membership via the
  /// same re-registration pattern as the focus-read marker; held so shutdown
  /// can cancel cleanly. Runs an initial sweep on first iteration to clean up
  /// entries inherited from prior launches.
  @ObservationIgnored private var orphanSweepTask: Task<Void, Never>?
  /// Live banner adapter; held so the Settings panel can call
  /// `requestAuthorization()` from the recovery button. Single instance
  /// per process — Settings panel reads via `@Environment` rather than
  /// spawning its own (each `init` re-runs setNotificationCategories
  /// on the shared center).
  @ObservationIgnored private(set) var osNotifier: UserNotificationsOSNotifier?
  /// Single chokepoint: gates every detector candidate against the
  /// settings toggles and drives the inbox + banner + dock badge in
  /// lockstep. Held so the lifetime tracks the app and so the dock-badge
  /// mirror task can call `recomputeDockBadge` on `unreadCount` changes
  /// that originate from non-coordinator paths (markRead, sweepOrphan...).
  @ObservationIgnored private(set) var notificationCoordinator: NotificationCoordinator?
  /// Classifies the agent driving each pane and persists the verdict via
  /// `HierarchyClient.setPaneAgentKind`. Constructed in
  /// `startNotificationObservers` (it shares the engine-event drain with
  /// `NotificationDetector`) and dispatched from the same `for await event`
  /// loop. Long-lived for the app lifetime.
  @ObservationIgnored private(set) var agentBinder: AgentBinder?
  /// Derived UI-side state machine for the badge + popover. Subscribes to
  /// four event sources (terminal events, keystrokes, focus, agent
  /// bind/unbind) wired in `startNotificationObservers`. Held long-lived
  /// so SwiftUI consumers outlive any scene reattach.
  @ObservationIgnored private(set) var agentStateStore: AgentStateStore?
  /// Long-running focus observer for AgentStateStore. Re-arms on every
  /// catalog mutation that could change the globally-focused pane and
  /// forwards new ids to `registry.onPaneFocused`. Same re-arming
  /// pattern as `observeFocusedPaneForRead`.
  @ObservationIgnored private var agentStateFocusTask: Task<Void, Never>?
  /// Keystroke side channel: per-pane "last user keystroke at" timestamps
  /// fed into the translator's `userTypingRecently` window. Strong reference
  /// here keeps the tracker alive; the `PaneKeyboardActivityTracker.shared`
  /// weak handle exposes it to the AppKit `GhosttySurfaceView` keystroke site.
  @ObservationIgnored private(set) var keystrokeTracker: PaneKeyboardActivityTracker?
  /// Backing reader behind `NotificationCoordinator`. Held so we can fire
  /// `refreshAuthorizationStatus` from the `applicationDidBecomeActive`
  /// hook below and so the `onChange` subscription stays alive for the
  /// process lifetime.
  @ObservationIgnored private var notificationSettingsReader: SettingsStoreReaderAdapter?
  /// Retains the settings-reader `onChange` subscription so the dock badge
  /// recomputes whenever any of the four notification toggles flips. Held
  /// here (rather than ignored) because dropping the cancellable would
  /// remove the handler and leave the badge stale.
  @ObservationIgnored private var notificationSettingsObserverToken: AnyCancellable?
  /// Listens for `NSApplication.didBecomeActiveNotification` and fires
  /// `coordinator.refreshAuthorizationStatus()`. Held so the observation
  /// outlives `bringUp` without strong-referencing AppState.
  @ObservationIgnored private var didBecomeActiveObserverToken: AnyCancellable?
  private(set) var terminalEngine: TerminalEngine?
  private(set) var store: StoreOf<RootFeature>?
  /// Long-lived store for the Settings window scene. Built during `bringUp()` so the
  /// store — and its in-memory editor-pane state — survives open/close cycles of the
  /// window.
  private(set) var settingsWindowStore: StoreOf<SettingsWindowFeature>?
  /// Shared dependency container for the Developer pane. Built at the tail
  /// of `bringUp()`; nil until then, which is why the Settings scene body
  /// renders a `ProgressView` placeholder.
  private(set) var developerPaneDependencies: DeveloperPaneDependencies?

  private let catalogStore: CatalogStore
  private let hierarchyRuntime: GhosttyBackedHierarchyRuntime
  private var ghosttyRuntime: GhosttyRuntime?
  /// Shared `sessions.json` store. Built lazily in `bringUp` (nil if the
  /// canonical URL cannot be opened — same fallback the IPC handlers use).
  /// Reused by `SessionLifecycle` so the quit-time flush and the in-app
  /// reap-on-pane-close path write through a single instance.
  @ObservationIgnored private(set) var sessionStore: SessionStore?
  /// Single writer that owns the in-memory `SessionCatalog` mirror and is
  /// the only mutator of `sessions.json` after launch. Bootstrap seeds it
  /// from `sessionStore.load()`; the launch reaper, the quit-time
  /// lifecycle, and the `pane.close` IPC handler all route through it.
  /// nil when the store is unavailable (no-resume mode).
  @ObservationIgnored private(set) var sessionCoordinator: SessionCoordinator?
  /// Quit-time orchestrator: snapshots every live `ZmxClient` into
  /// `sessions.json` and then sends `.detach` so the daemons survive the
  /// app process. Built in `bringUp` alongside the engine; nil before
  /// then, which keeps the `willTerminate` observer safe to fire early.
  @ObservationIgnored private(set) var sessionLifecycle: SessionLifecycle?
  /// Per-pane daemon liveness the launch `SessionReaper.sweep` already
  /// determined, keyed by `PaneID` (`true` == socket reachable). Consumed by
  /// `seedRestoredAgents` so the agent-state seed reuses the sweep's verdict
  /// instead of re-`connect(2)`-probing the same panes. Empty until the
  /// sweep runs (and on the no-resume / keepRunning paths), where the seed
  /// falls back to a direct per-pane probe.
  @ObservationIgnored private var sessionSweepLiveness: [PaneID: Bool] = [:]
  /// Per-Worktree "git status is non-clean" cache. The sidebar row's `.task(id:)`
  /// refreshes this lazily; a small dot is drawn next to the row name when dirty.
  let worktreeStatusMonitor: WorktreeStatusMonitor
  /// Per-Worktree "uncommitted edits" line counts (`git diff HEAD
  /// --shortstat`). Drives the `+N −M` chip on sidebar worktree rows
  /// regardless of PR state. Shared with the reducer via the
  /// `WorktreeLocalDiffMonitor` DependencyKey so HEAD-watcher events can
  /// invalidate the cache.
  let worktreeLocalDiffMonitor: WorktreeLocalDiffMonitor

  /// Watches `.git/HEAD` for every catalog Worktree so terminal-driven
  /// `git checkout` inside a pane propagates to the catalog row's `branch`
  /// (and downstream PR badges) without waiting for the next app-focus
  /// event. Created here so its lifetime tracks the app and the
  /// catalog-sync task lives inside `bringUp`.
  let worktreeHeadWatcher: WorktreeHeadWatcher
  private var worktreeHeadWatcherSyncTask: Task<Void, Never>?

  /// FSEvents observer on each Worktree's working-tree subtree. Refreshes
  /// the `+N −M` diff chip after in-pane / in-editor edits — changes that
  /// move `git diff HEAD` without touching `.git/HEAD`, so the head watcher
  /// never fires for them. Created here so its lifetime tracks the app and
  /// the catalog-sync task lives inside `bringUp`.
  let worktreeWorkingTreeWatcher: WorktreeWorkingTreeWatcher
  private var worktreeWorkingTreeWatcherSyncTask: Task<Void, Never>?

  private var socketServer: SocketServer?
  // EditorClient is built inside bringUp() alongside the TCA dependency
  // wiring and then threaded into startIPC() so EditorHandlers and the
  // in-app reducer stack share a single service instance.
  private var editorClient: EditorClient?
  private var hierarchyClient: HierarchyClient?

  /// Master Terminal: app-level summon-by-hotkey panel that hosts a
  /// `claude remote-control` session. Wired in `bringUp()`. The controller
  /// + hotkey live for the app lifetime; the controller itself is lazy
  /// internally (no NSPanel constructed until first toggle).
  private var masterTerminalController: MasterTerminalController?
  private var masterTerminalHotkey: MasterTerminalHotkey?

  init() {
    let catalogStore = CatalogStore()
    let runtime = GhosttyBackedHierarchyRuntime()
    let catalog = (try? catalogStore.load()) ?? .empty

    let manager = HierarchyManager(
      catalog: catalog,
      store: catalogStore,
      runtime: runtime
    )

    self.catalogStore = catalogStore
    self.hierarchyRuntime = runtime
    self.hierarchyManager = manager
    let settingsStore = SettingsStore()
    self.settingsStore = settingsStore
    // Wired here rather than at the `HierarchyClient` seam: `codans project
    // rm` reaches `HierarchyHandlers`, which calls the manager directly and
    // never passes through the client.
    manager.onProjectRemoved = { [weak settingsStore] projectID in
      settingsStore?.removeProjectSettings(projectID)
    }
    self.shortcutsStore = ShortcutsStore()
    self.notificationStore = NotificationStore()
    self.worktreeStatusMonitor = .live()
    self.worktreeLocalDiffMonitor = .live()
    self.worktreeHeadWatcher = WorktreeHeadWatcher()
    self.worktreeWorkingTreeWatcher = WorktreeWorkingTreeWatcher()
  }

  /// Idempotent: subsequent calls while `store` is already set are no-ops.
  /// SwiftUI may re-run `.task` on scene transitions; the guard prevents
  /// rebuilding the engine + store and leaking the prior runtime.
  func bringUp() {  // swiftlint:disable:this function_body_length
    guard store == nil else { return }
    // Phase-time the synchronous bring-up so a slow launch is attributable
    // to a specific stage from Console alone (see `LaunchProfiler`).
    let profiler = LaunchProfiler()
    // Detached from bring-up: the probe spawns a login shell to resolve PATH,
    // and nothing on the launch path blocks on the answer (both readers treat
    // "not scanned yet" as "assume installed").
    Task { [agentInstallation] in await agentInstallation.scanIfNeeded() }
    let ghostty = try? GhosttyRuntime()
    self.ghosttyRuntime = ghostty
    let engine = TerminalEngine(
      store: catalogStore,
      hierarchy: hierarchyManager,
      ghosttyRuntime: ghostty
    )
    self.terminalEngine = engine
    hierarchyRuntime.attach(engine: engine)
    profiler.mark("ghostty+engine")
    bootstrapSessionStack(ghostty: ghostty, engine: engine, profiler: profiler)

    // SettingsStore loads itself (and migrates legacy formats) during `init(fileURL:)`.
    let manager = hierarchyManager
    let settings = settingsStore

    // Build the editor + hierarchy clients once so the reducer stack AND the IPC
    // handlers share the exact same live instances — avoids two parallel
    // `LiveEditorService`s with divergent settings captures.
    let editor = EditorClient.live(settings: settings)
    // Server-project transport seam for the worktree-management surface:
    // paths owned by a remote project route their plain-git operations
    // (listing, branch queries, removal, prune, status) over SSH. Shared by
    // the HierarchyClient (reconcile + removal) and the root store (create
    // sheet option loading) so both sides agree on the transport.
    let worktreeClient = GitWorktreeClient.makeLive(
      remoteHostResolver: { [weak manager] path in
        await MainActor.run { manager?.remoteHost(forPath: path) }
      }
    )
    let hierarchy = HierarchyClient.live(
      manager: manager,
      settings: settings,
      gitWorktreeClient: worktreeClient,
      terminalClient: .live(engine: engine)
    )
    self.editorClient = editor
    self.hierarchyClient = hierarchy

    // Server-project git transport: a GitService whose invocations route over
    // SSH whenever the repository path belongs to a remote project (resolved
    // live against the manager's catalog). Installed on the root store (below)
    // and rebound into the two sidebar monitors, so the `+N −M` chip, dirty
    // flag, PR badge remote-URL probe, branch switcher, and diff inspector all
    // work against remote worktrees with no per-feature changes. The global
    // `gitService` prepared in `CodansApp.init` stays purely local — it cannot
    // be re-prepared, and no view-side reader needs the remote route.
    let routedGitClient = GitServiceClient.live(
      service: Git.makeService(remoteHostResolver: { [weak manager] url in
        await MainActor.run { manager?.remoteHost(forPath: url.path) }
      })
    )
    worktreeStatusMonitor.rebindFetch(routedGitClient.status)
    worktreeLocalDiffMonitor.rebindFetch(routedGitClient.localDiffStats)

    // Notification observers + coordinator depend on `hierarchy` (the
    // coordinator captures `HierarchyClient` so it can call
    // `reorderWorktrees`). Construct them AFTER `hierarchy` is built but
    // BEFORE the RootStore wire-up so the detector task is already
    // draining engine events by the time the reducer is alive.
    startNotificationObservers(
      manager: manager,
      engine: engine,
      settings: settings,
      hierarchy: hierarchy
    )
    profiler.mark("observers")
    // Wire the quit-time agent snapshot into SessionLifecycle now that
    // both the registry and the engine (PID source) are alive. The
    // closure is invoked from the lifecycle's `detachLiveTier` path —
    // running here keeps lifecycle ignorant of `AgentStateStore`'s type.
    if let lifecycle = self.sessionLifecycle, let registry = self.agentStateStore {
      lifecycle.agentSnapshotProvider = { [weak engine, weak registry] in
        guard let registry else { return [] }
        let now = Date()
        return registry.entries.map { paneID, entry in
          PersistedAgentRecord(
            paneID: paneID,
            kindRaw: entry.kind.rawValue,
            stateRaw: entry.state.rawValue,
            pid: engine?.foregroundProcessGroupID(for: paneID) ?? 0,
            capturedAt: now
          )
        }
      }
    }
    // SwiftUI views (e.g. `ProjectGeneralSettingsView`) read `@Dependency(SettingsWriter.self)`
    // directly; that resolution bypasses the per-store `withDependencies` overrides below and
    // would otherwise hit the `liveValue` `fatalError` placeholders. Install the live
    // implementations as the global defaults before any view body runs so View-side reads
    // find the wired instances. Reducer-side overrides on the Store layer on top of these.
    // Only the engine/state-dependent clients are prepared here — they need
    // `engine` / `hierarchy` / `settings`, which exist only after bring-up.
    // The pure-Foundation built-ins (`date`, clocks, `uuid`) and the stateless
    // git clients are already prepared in `CodansApp.init`, which also
    // satisfies the XCTest-host defense (unset keys would otherwise fall back
    // to `unimplemented`). Re-preparing them here trips swift-dependencies'
    // "a global dependency can only be prepared a single time" runtime warning,
    // so they are intentionally not repeated.
    prepareDependencies {
      $0.editorClient = editor
      $0.hierarchyClient = hierarchy
      $0.settingsWriter = .live(settings)
      $0.terminalClient = .live(engine: engine)
    }

    // Sparkle bringup: push persisted Updates preferences to the live updater so
    // settings.json is the single source of truth (Sparkle's own NSUserDefaults are
    // derived from this, not the other way around). When auto-checks are enabled we
    // also force one background probe — Sparkle's built-in scheduler is gated by
    // `lastUpdateCheckDate + updateCheckInterval` and would otherwise skip checking
    // for the rest of the interval, so a release published mid-interval is invisible
    // to users until the next tick. `checkForUpdatesInBackground()` is silent and
    // edSignature-verified, so the extra request per launch is cheap and safe.
    let general = settings.settings.general
    UpdatesClient.liveValue.applyPreferences(
      general.updateChannel,
      general.updateCheckInterval,
      general.updatesAutomaticallyCheckForUpdates,
      general.updatesAutomaticallyDownloadUpdates,
      general.updatesAutomaticallyCheckForUpdates
    )
    // `SettingsWindowPresenter.open` forwards to the `OpenWindowAction` captured by the
    // main-window scene body into `openSettingsWindowAction`. SwiftUI's `OpenWindowAction`
    // must be read from a `View`'s environment so the reducer cannot hold it directly —
    // this indirection is what lets `RootFeature` trigger an open without pulling
    // `@Environment(\.openWindow)` into TCA.
    let presenter = SettingsWindowPresenter(
      open: { [weak self] in
        self?.openSettingsWindowAction?()
      },
      openAt: { [weak self] section in
        guard let self else { return }
        // Open the window first so the scene is visible / brought-to-front,
        // then push the selection into the settings store. The store
        // already exists by this point (built earlier in `bringUp`).
        self.openSettingsWindowAction?()
        self.settingsWindowStore?.send(.selectionChanged(section))
      }
    )
    // Handoff transition core, shared by the `handoff.*` IPC handler and the
    // in-app Hand Off panel's fallback so both run the exact same sequence.
    let handoffHandlers = makeHandoffHandlers(
      hierarchy: manager, hierarchyClient: hierarchy,
      settingsStore: settings, engine: engine, gitClient: routedGitClient
    )
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = hierarchy
      $0.handoffClient = .live(
        handlers: handoffHandlers,
        registry: self.handoffRegistry,
        engine: engine,
        cli: Self.cliInvocation(),
        installation: self.agentInstallation,
        source: { [weak self, weak manager] paneID in
          guard let manager else { return nil }
          return Self.handoffSource(
            for: paneID, manager: manager, agentState: self?.agentStateStore)
        }
      )
      $0.terminalClient = .live(engine: engine)
      // SSH-routing git clients (see construction above) so every reducer-side
      // git consumer transparently reaches Server-project repositories.
      $0.gitService = routedGitClient
      $0.gitWorktreeClient = worktreeClient
      // Without these overrides, `EditorClient.liveValue` and
      // `SettingsWriter.liveValue` fatalError on any descendants call. Both factories close
      // over `settings` (global default + custom templates); `editorClient` additionally
      // closes over `manager` (per-Project override).
      $0.editorClient = editor
      $0.settingsWriter = .live(settings)
      $0.settingsWindowPresenter = presenter
      // Project Management: reconciler captures the live HierarchyClient so
      // `.reconcileDiscoveredWorktrees` flows through the real manager
      // binding. Default `now` is `Date.init`; tests override with a
      // scripted closure.
      $0.projectReconciler = ProjectReconciler(client: hierarchy)
      $0.worktreeHeadWatcher = self.worktreeHeadWatcher
      $0.worktreeWorkingTreeWatcher = self.worktreeWorkingTreeWatcher
      $0.worktreeLocalDiffMonitor = self.worktreeLocalDiffMonitor
      // Built-in TCA dependencies (`\.date`, `\.continuousClock`, `\.uuid`) are
      // always swapped to `unimplemented` under XCTest regardless of any
      // process-wide `prepareDependencies` — swift-dependencies guards these
      // controllable keys explicitly so tests can't accidentally rely on real
      // time. The live store has no such constraint; pin the production
      // defaults at the Store boundary so any reducer effect that captures
      // them keeps working when the app boots inside a test host.
      $0.date = .init { Date() }
      $0.continuousClock = ContinuousClock()
      $0.suspendingClock = SuspendingClock()
      $0.uuid = .init { UUID() }
    }
    profiler.mark("store")

    startHeadWatcherSync()
    startWorkingTreeWatcherSync()

    self.settingsWindowStore = Store(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.editorClient = editor
      $0.settingsWriter = .live(settings)
      $0.hierarchyClient = hierarchy
      $0[GhosttyTerminalSettingsClient.self] = .appLive()
    }

    startIPC(
      hierarchy: manager, editor: editor, hierarchyClient: hierarchy,
      settingsStore: settings, terminalEngine: engine, handoffHandlers: handoffHandlers
    )

    self.developerPaneDependencies = DeveloperPaneDependencies.live(
      settingsURL: Settings.defaultURL()
    )

    // Master Terminal: idempotent filesystem seed for ~/.config/codans/master-terminal/.
    // Failure to seed must not block app bring-up — the Master Terminal feature
    // simply won't have a working directory until the next launch.
    do {
      try MasterTerminalBootstrap.ensureUserDirectory()
    } catch {
      Logger.masterTerminal.error(
        "bootstrap failed: \(String(describing: error), privacy: .public)"
      )
    }

    // Master Terminal hotkey: ⌥⌘` toggles the slide-in panel. Hard-coded
    // for now; promotion to ShortcutsStore is deferred until that store
    // grows a "global hotkey" scope.
    //
    // Skipped if GhosttyRuntime failed to initialise — without it the panel
    // would slide in empty, with no path to recover. The same guard already
    // gates the rest of the terminal stack.
    if let ghostty {
      let controller = MasterTerminalController(runtime: ghostty)
      self.masterTerminalController = controller
      self.masterTerminalHotkey = MasterTerminalHotkey(onTrigger: { [weak controller] in
        controller?.toggle()
      })
    }
    profiler.mark("finish")
  }

  private func startNotificationObservers(
    manager: HierarchyManager,
    engine: TerminalEngine,
    settings: SettingsStore,
    hierarchy: HierarchyClient
  ) {
    let osNotifier = UserNotificationsOSNotifier()
    self.osNotifier = osNotifier

    // Chokepoint: the coordinator gates every candidate against the
    // four `settings.notifications` toggles and drives the inbox + dock
    // badge + system banner in lockstep. The detector hands it a
    // pre-classified `Candidate` (sourceIsFocused already resolved).
    let settingsReader = SettingsStoreReaderAdapter(
      settingsStore: settings,
      osNotifier: osNotifier
    )
    let coordinator = NotificationCoordinator(
      inbox: notificationStore,
      osNotifier: osNotifier,
      settingsReader: settingsReader,
      catalog: hierarchy,
      now: { Date() }
    )
    self.notificationSettingsReader = settingsReader
    self.notificationCoordinator = coordinator

    // Keystroke side channel: AppKit-side key events are recorded
    // through `PaneKeyboardActivityTracker.shared` from `GhosttySurfaceView`;
    // the detector snapshots the map into each translator Context. Published
    // to the shared static handle here so newly constructed surfaces find
    // a live tracker regardless of construction order.
    let keystrokeTracker = PaneKeyboardActivityTracker()
    self.keystrokeTracker = keystrokeTracker
    PaneKeyboardActivityTracker.shared = keystrokeTracker

    let detector = NotificationDetector(
      store: notificationStore,
      coordinator: coordinator,
      tracker: keystrokeTracker,
      settingsReader: settingsReader,
      catalogSnapshot: { manager.catalog },
      lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) },
      onProjectActivity: { [weak manager] projectID in
        manager?.bumpProjectActivity(projectID)
      }
    )
    // Build the binder and registry, install the five-wire fan-out
    // (terminal events / running set / keystrokes / focus / agent bind),
    // and start the long-running drain. Extracted into a helper so this
    // function stays under the lint body length.
    startAgentStateObservers(
      manager: manager,
      engine: engine,
      hierarchy: hierarchy,
      detector: detector,
      keystrokeTracker: keystrokeTracker
    )

    let inbox = notificationStore
    // Initial badge paint goes through the coordinator so the dock honours
    // both `inAppEnabled` and `dockBadgeEnabled` from the very first frame.
    coordinator.recomputeDockBadge()
    // Mirror `inbox.unreadCount` to the dock badge via the coordinator so
    // mutations from non-coordinator paths (markRead / markAllRead /
    // sweepOrphanUnreads) still honour the live toggles.
    self.dockBadgerTask = Task { @MainActor [weak coordinator] in
      await Self.observeDockBadge(store: inbox, coordinator: coordinator)
    }
    // Re-paint the badge on any settings flip that affects either of the
    // two gates that govern it.
    self.notificationSettingsObserverToken = settingsReader.onChange { [weak coordinator] in
      coordinator?.recomputeDockBadge()
    }
    // Kick off the initial authorization-status refresh, then arm the
    // didBecomeActive observer so a user who flips Notifications in
    // System Settings sees the cached `authStatus` catch up next time
    // they return to the app.
    Task { @MainActor [weak coordinator] in
      await coordinator?.refreshAuthorizationStatus()
    }
    // If the inbox file was quarantined on load (a forward-version
    // `notifications.json` was renamed aside on boot), fire a one-shot
    // synthetic "Inbox reset" notification. The coordinator persists an
    // idempotency marker so the same quarantine event does not re-surface
    // on every relaunch. Scheduled AFTER `refreshAuthorizationStatus` so
    // the cached `authStatus` is fresh by the time the synthetic candidate
    // hits the chokepoint and tries to OS-post.
    if let quarantineBackup = notificationStore.loadedQuarantineBackupURL {
      Task { @MainActor [weak coordinator] in
        await coordinator?.emitQuarantineNotice(backupURL: quarantineBackup)
      }
    }
    self.didBecomeActiveObserverToken = NotificationCenter.default
      .publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak coordinator] _ in
        Task { @MainActor [weak coordinator] in
          await coordinator?.refreshAuthorizationStatus()
        }
      }

    self.focusReadMarkerTask = Task { @MainActor in
      await Self.observeFocusedPaneForRead(
        catalog: { manager.catalog }, lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) }, store: inbox)
    }
    self.orphanSweepTask = Task { @MainActor in
      await Self.observeOrphanUnreadsSweep(catalog: { manager.catalog }, store: inbox)
    }
    self.notificationRollup = RollupIndexProvider(
      store: inbox,
      focus: { [weak manager] in
        guard let manager else { return RollupFocusState() }
        return Self.focusState(from: manager.catalog, lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) })
      },
      observe: { [weak manager] in
        guard let manager else { return }
        _ = manager.catalog.selectedProjectID
        for project in manager.catalog.projects {
          _ = project.selectedWorktreeID
          _ = project.isExpanded
          for worktree in project.worktrees {
            _ = worktree.selectedTabID
          }
        }
      }
    )
  }

  /// Closure the main-window scene body installs to bridge TCA → `openWindow(id: "settings")`.
  /// Set from `.task { appState.openSettingsWindowAction = { openWindow(id: settingsWindowID) } }`
  /// inside `CodansApp.body`. The presenter dependency captures `self` weakly and
  /// forwards `.open()` through this closure.
  @ObservationIgnored var openSettingsWindowAction: (@MainActor () -> Void)?

  /// Wires the SocketServer so `codans` CLI can talk to the running app.
  /// Skipped under XCTest — tests build their own in-memory harnesses and
  /// binding a shared Unix socket racing parallel runs makes the runner
  /// hang.
  private func startIPC(
    hierarchy: HierarchyManager,
    editor: EditorClient,
    hierarchyClient: HierarchyClient,
    settingsStore: SettingsStore,
    terminalEngine: TerminalEngine,
    handoffHandlers: HandoffHandlers
  ) {
    if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    {
      return
    }

    let systemHandlers = SystemHandlers(
      versions: .init(
        server: Self.bundleVersion(),
        appBundle: Self.bundleVersion()
      )
    )
    // SessionCoordinator backs the `pane.close` reap step. We reuse the
    // shared instance built in `bringUp` so the IPC handlers and the
    // quit-time `SessionLifecycle` flush write through one in-memory
    // truth; nil falls back to the handler's "no persistent catalog to
    // reap" path (second-instance no-resume mode).
    let sessionCoordinator = self.sessionCoordinator
    let hierarchyHandlers = HierarchyHandlers(
      manager: hierarchy,
      envProvider: { projectID in
        HierarchyManager.resolvedEnv(for: projectID, in: settingsStore.settings)
      },
      settingsProvider: { settingsStore.settings },
      daemonKiller: { paneID in
        // Killing a pane's daemon is an out-of-band control `.kill`,
        // addressable by PaneID alone, so it works whether or not a surface
        // is live this session (the live byte stream runs through the
        // in-surface `zmx attach` client, not a held handle). The daemon
        // removes its own socket on shutdown, so no manual unlink is needed.
        ZmxControlClient.kill(for: paneID)
      },
      runtimeProbe: { [weak terminalEngine] paneID in
        // `pane.info` / `pane.read` probe the daemon out-of-band via its
        // control socket. Gate on a live surface so we don't hand back a
        // probe for a pane whose daemon isn't running this session.
        guard terminalEngine?.ghosttyRuntime?.surface(for: paneID) != nil else {
          return nil
        }
        return ZmxControlProbe(paneID: paneID)
      },
      sessionCoordinator: sessionCoordinator,
      callerPaneResolver: { [weak terminalEngine] callerPID in
        // Ground-truth caller attribution: match the connecting process's
        // ancestry against every live pane's daemon shell PID. Covers CLI
        // calls whose environment lost CODANS_PANE_ID (agent-spawned
        // subshells, wrappers) — the ancestor chain still passes through
        // the pane's shell. The snapshot is rebuilt per call; the map is
        // small (one entry per live pane) and shell PIDs can change
        // across pane restarts, so caching would risk staleness.
        guard let runtime = terminalEngine?.ghosttyRuntime else { return nil }
        var paneByShellPID: [pid_t: PaneID] = [:]
        for surface in runtime.allLiveSurfaces() {
          guard let shellPID = surface.childProcessID() else { continue }
          paneByShellPID[shellPID] = surface.paneID
        }
        return CallerPaneResolver.resolve(callerPID: callerPID, paneByShellPID: paneByShellPID)
      }
    )
    let inputSink: TerminalInputSink? =
      terminalEngine.ghosttyRuntime == nil
      ? nil
      : TerminalInputSink(
        engine: terminalEngine,
        onPaneInput: { [weak hierarchy] paneID in
          guard let manager = hierarchy,
            let projectID = manager.catalog.projectID(forPane: paneID)
          else { return }
          manager.bumpProjectActivity(projectID)
        }
      )
    let terminalHandlers = TerminalHandlers(
      sink: inputSink,
      catalog: { hierarchy.catalog }
    )
    let editorHandlers = EditorHandlers(
      editor: editor,
      hierarchy: hierarchyClient,
      settings: settingsStore
    )
    let projectHandlers = ProjectHandlers(
      settings: settingsStore,
      hierarchy: hierarchyClient
    )
    let router = MethodRouter(
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers,
      editorHandlers: editorHandlers,
      projectHandlers: projectHandlers,
      agentHandlers: AgentHandlers(
        settings: settingsStore,
        hierarchy: hierarchyClient,
        installation: agentInstallation
      ),
      handoffHandlers: handoffHandlers
    )
    let resolvedSocketPath = SocketPaths.resolve()
    let server = SocketServer(path: resolvedSocketPath, router: router)
    do {
      try server.start()
      self.socketServer = server
    } catch {
      // GUI launches discard stderr, so a `print` here would have been invisible.
      // Log to the unified system log so `log show --subsystem com.gumpw.codans.ipc`
      // surfaces silent IPC bring-up failures (e.g., stale socket, prod sock
      // squatting on dev path via `$CODANS_SOCKET_PATH`).
      Logger.ipcServer.error(
        "SocketServer bind failed at \(resolvedSocketPath, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Handoff transition core wired to the live runtime: pane → source
  /// through the catalog + `AgentStateStore`, screen text straight off the
  /// pane's surface, git facts through the SSH-routed git client, and the
  /// receiver launch through the shared agent pipeline.
  private func makeHandoffHandlers(
    hierarchy: HierarchyManager,
    hierarchyClient: HierarchyClient,
    settingsStore: SettingsStore,
    engine: TerminalEngine,
    gitClient: GitServiceClient
  ) -> HandoffHandlers {
    HandoffHandlers(
      settings: settingsStore,
      registry: handoffRegistry,
      resolveSource: { [weak hierarchy, weak self] paneID in
        guard let manager = hierarchy else { return nil }
        return Self.handoffSource(
          for: paneID, manager: manager, agentState: self?.agentStateStore)
      },
      readScreen: { [weak engine] paneID in
        engine?.ghosttyRuntime?.surface(for: paneID)?.readText(.viewport)
      },
      collectRepoState: { root in
        await Self.handoffRepoState(at: root, git: gitClient)
      },
      launch: { spec in try await hierarchyClient.launchAgent(spec) },
      typeKickoff: { [weak self, weak engine] paneID, kind, prompt in
        guard let engine, let agentState = self?.agentStateStore else { return false }
        return await Self.typeKickoffOnceAgentIsUp(
          paneID: paneID, kind: kind, prompt: prompt, agentState: agentState, engine: engine)
      },
      cli: Self.cliInvocation()
    )
  }

  /// Kickoff delivery for a receiver whose CLI takes no prompt argument.
  /// Waits until the classifier sees `kind` in the pane — typing earlier would
  /// hand the text to the shell — then until the screen has stopped changing,
  /// so the TUI has drawn its input box rather than still loading; types the
  /// prompt; and submits it once the screen shows the text sitting in the
  /// input box. An agent that never appears gets nothing.
  ///
  /// The Enter is conditional on that last check. A TUI that opens on a dialog
  /// (an update prompt, first-run setup) swallows the typed letters, and an
  /// Enter there would answer the dialog instead of sending anything; when the
  /// text is not on screen nothing is submitted and the miss is logged.
  /// OpenCode folds a typed burst into a "[Pasted ~N lines]" chip, which counts
  /// as "on screen".
  static func typeKickoffOnceAgentIsUp(
    paneID: PaneID,
    kind: AgentKind,
    prompt: String,
    agentState: AgentStateStore,
    engine: TerminalEngine,
    timeout: Duration = .seconds(30),
    settle: Duration = .milliseconds(1500)
  ) async -> Bool {
    let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "handoff")
    let deadline = ContinuousClock.now + timeout
    while agentState.entries[paneID]?.kind != kind {
      guard ContinuousClock.now < deadline else {
        logger.error(
          "kickoff: \(kind.rawValue, privacy: .public) never appeared in pane \(paneID.description, privacy: .public)")
        return false
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    guard let surface = engine.ghosttyRuntime?.surface(for: paneID) else {
      logger.error("kickoff: pane \(paneID.description, privacy: .public) has no surface to type into")
      return false
    }
    // Ready = the screen held still for `settle` (at least one full read
    // apart), capped so a TUI with a spinner still gets its prompt.
    var previous = surface.readText(.active) ?? ""
    var stillSince = ContinuousClock.now
    let readyDeadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < readyDeadline {
      try? await Task.sleep(for: .milliseconds(250))
      let current = surface.readText(.active) ?? ""
      if current != previous {
        previous = current
        stillSince = ContinuousClock.now
      } else if ContinuousClock.now - stillSince >= settle, !current.isEmpty {
        break
      }
    }
    surface.sendInput(prompt)
    let marker = String(prompt.prefix(19))
    for _ in 0..<12 {
      try? await Task.sleep(for: .milliseconds(250))
      guard let screen = surface.readText(.active) else { continue }
      if screen.contains(marker) || screen.contains("Pasted") {
        // CR is what TUIs read as Enter; LF only breaks the line.
        surface.sendInput("\r")
        return true
      }
    }
    logger.error(
      "kickoff: typed into pane \(paneID.description, privacy: .public) but the text never showed on screen; not submitted")
    return false
  }

  /// Resolves a pane to the outgoing side of a handoff. Agent identity
  /// prefers the live `AgentStateStore` entry (what the classifier sees
  /// now) and falls back to the persisted pane binding, so a pane restored
  /// after relaunch still names its agent.
  static func handoffSource(
    for paneID: PaneID,
    manager: HierarchyManager,
    agentState: AgentStateStore?
  ) -> HandoffSource? {
    guard let (projectID, worktreeID, tabID) = manager.addressOf(paneID: paneID),
      let project = manager.catalog.projects.first(where: { $0.id == projectID }),
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let tab = worktree.tabs.first(where: { $0.id == tabID })
    else { return nil }
    let pane = tab.panes.first { $0.id == paneID }
    let entry = agentState?.entries[paneID]
    return HandoffSource(
      paneID: paneID,
      projectID: projectID,
      worktreeID: worktreeID,
      tabID: tabID,
      worktreePath: worktree.path,
      isRemote: project.isRemote,
      agentKind: entry?.kind ?? pane?.agentKind,
      sessionID: entry?.sessionID ?? pane?.agentSessionID,
      paneTitle: tab.cachedDisplayTitle ?? tab.name
    )
  }

  /// How this app writes its own CLI in a command an agent will run. Prefers
  /// the installed command name, and falls back to the bundled binary's
  /// absolute path when this build's CLI was never installed — a Debug app
  /// must not write plain `codans`, which the Release app would answer.
  nonisolated static func cliInvocation() -> String {
    CLIInvocation.command(bundledBinary: try? CLIBundleLocator.locateBinary())
  }

  /// Git facts for `context.md`. Read-only (`status`, branch, shortstat);
  /// any failure — not a repository, git missing — degrades to "not git"
  /// rather than blocking the handoff.
  nonisolated static func handoffRepoState(at root: URL, git: GitServiceClient) async -> HandoffRepoState {
    guard let status = try? await git.status(root) else { return .notGit }
    let branch = try? await git.currentBranch(root)
    let stats = (try? await git.localDiffStats(root)) ?? nil
    return HandoffRepoState(
      branch: branch ?? nil,
      isGit: true,
      changedFiles: status.entries.map(\.path),
      additions: stats?.additions ?? 0,
      deletions: stats?.deletions ?? 0
    )
  }

  static func bundleVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
  }

  /// Open the shared `sessions.json` store once and stand up the quit-time
  /// `SessionLifecycle` against it. Failure to open is non-fatal — the
  /// lifecycle stays nil (so `willTerminate` skips the detach pass) and
  /// the IPC handlers fall back to "no persistent catalog to reap" (their
  /// existing behaviour). Extracted from `bringUp` to keep that method
  /// under the SwiftLint function-body cap.
  ///
  /// Also drives the launch-time reaper: every catalog row whose daemon
  /// socket still answers `connect(2)` is seeded into the engine so the
  /// next `ensureSurface` for that paneID reattaches instead of spawning
  /// a fresh daemon. Dead rows are pruned from the catalog as part of
  /// the sweep.
  private func bootstrapSessionStack(
    ghostty: GhosttyRuntime?, engine: TerminalEngine, profiler: LaunchProfiler
  ) {
    let sessionStore: SessionStore?
    do {
      sessionStore = try SessionStore(fileURL: SessionCatalog.defaultURL())
    } catch SessionStoreError.alreadyHeld {
      // Second codans instance: the primary process holds the
      // LOCK_EX on `sessions.json`. Degrade to "no-resume mode" —
      // every pane cold-starts, the quit-time `SessionLifecycle`
      // skips its detach/snapshot pass, and the launch-time reaper
      // is never built. Daemons spawned by this instance are still
      // `setsid`-detached, but they will not be added to the
      // catalog and therefore won't be reattached on the next launch.
      Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.session")
        .info("sessions.json already locked by another instance; entering no-resume mode")
      self.sessionStore = nil
      return
    } catch {
      // Any other init failure (open(2) refused, flock errno that
      // isn't EWOULDBLOCK) — log and fall through to the same
      // no-resume mode. Aligns with the original `try?` semantics:
      // the worst outcome is a fresh shell per pane.
      Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.session")
        .error("SessionStore init failed: \(String(describing: error), privacy: .public)")
      self.sessionStore = nil
      return
    }
    self.sessionStore = sessionStore
    guard let sessionStore else { return }
    // Seed the coordinator's in-memory catalog from disk once at bootstrap.
    // A read error (corrupt file, EIO under sandbox revoke) degrades to an
    // empty catalog rather than blocking the launch — same failure mode as
    // the previous direct-load path inside `SessionReaper.sweep`.
    let initialCatalog: SessionCatalog
    do {
      initialCatalog = try sessionStore.load()
    } catch {
      Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.session")
        .error("SessionStore.load failed at bootstrap: \(String(describing: error), privacy: .public)")
      initialCatalog = .empty
    }
    let coordinator = SessionCoordinator(store: sessionStore, initial: initialCatalog)
    self.sessionCoordinator = coordinator
    // Wire the coordinator into the engine so every fresh spawn /
    // reattach / restore writes a row through the debounced store. The
    // engine builds before this function runs (see `bringUp`), so we set
    // the property after construction instead of through `init` — the
    // engine treats nil as "no-resume mode" and silently skips writes.
    engine.sessionCoordinator = coordinator
    self.sessionLifecycle = SessionLifecycle(
      manager: hierarchyManager,
      ghosttyRuntime: ghostty,
      coordinator: coordinator
    )

    let reaper = SessionReaper(coordinator: coordinator)
    let livePaneIDs = hierarchyManager.catalog.allPaneIDs()
    do {
      // Pass the current hierarchy's pane ids so the reaper can kill any
      // alive daemon whose paneID no longer maps to a surface — without
      // this, an out-of-sync sessions.json vs hierarchy.json would leak
      // daemons until the 7-day stale window catches them.
      //
      // The sweep's `.snapshot(url)` states name panes whose daemon is
      // gone but a quit-time `<paneID>.snap` survives on disk. Thread
      // those into the engine BEFORE bring-up so the next `ensureSurface`
      // for each paneID spawns `zmx attach … --restore-from <url>` exactly
      // once. `.alive`/`.dead` states are not restores and are ignored
      // here — restore is driven purely by snapshot presence, never by the
      // current on-quit resume setting.
      let states = try reaper.sweep(livePaneIDs: livePaneIDs)
      engine.pendingRestores = Self.derivePendingRestores(from: states)
      // The sweep already probed every session socket; reuse its verdict so
      // the agent-state seed doesn't re-`connect(2)` the same panes a second
      // time (a wedged daemon would otherwise stall launch twice). Panes
      // absent from this map — e.g. the keepRunning quit path persists
      // `sessions: [:]` — fall back to a direct probe in `seedRestoredAgents`.
      self.sessionSweepLiveness = Self.deriveLiveness(from: states)
    } catch {
      // A corrupt catalog or transient I/O error must not block app
      // launch — the worst outcome is a fresh shell per pane. Leave
      // `pendingRestores` empty so every pane cold-starts
      // (degrade-to-cold-start). Log via os.Logger so a chronic failure
      // surfaces in Console.
      Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.session.reaper")
        .error("SessionReaper.sweep failed: \(String(describing: error), privacy: .public)")
    }
    profiler.mark("session sweep")

    // Defense-in-depth: catch daemons whose socket files outlive both
    // the catalog and the hierarchy (e.g. crash mid-spawn before the row
    // was persisted, or daemons left by an older build whose catalog row
    // was wiped). Runs after `sweep` so the catalog is already pruned to
    // the surviving set — anything still on disk after this point is a
    // true filesystem orphan.
    //
    // Deferred off the synchronous bring-up path: it scans a directory and
    // `connect(2)`-probes every stray socket, none of which feed
    // `pendingRestores` (only `sweep` above does), so it has no bearing on
    // the first frame or on session restore. Running it in a follow-up task
    // keeps its filesystem + socket work from stalling the launch while
    // still reaping orphans moments later. `livePaneIDs` is captured by
    // value — the pruned set from this sweep is exactly what the orphan pass
    // needs.
    Task { @MainActor in
      reaper.sweepFilesystemOrphans(livePaneIDs: livePaneIDs)
    }
  }

  /// User-initiated "Forget all sessions" from Settings → General. The
  /// action must terminate every recorded daemon, unlink each socket, AND
  /// empty the catalog — otherwise the next `detachAllForQuit` rebuilds the
  /// catalog from the still-alive daemons (`collectLiveClients`) and
  /// effectively undoes the "forget".
  ///
  /// Order: kill + unlink first, then clear the catalog. If the kill
  /// step fails per-daemon (already-dead socket, etc.) the launch-time
  /// FS-orphan reaper catches the leftover. `coordinator.forgetAllSessions`
  /// drives both steps in one atomic-from-the-UI's-perspective call.
  func forgetAllPersistedSessions() {
    guard let coordinator = sessionCoordinator else { return }
    do {
      try coordinator.forgetAllSessions { socketPath in
        SessionReaper.sendOneShotKill(socketPath: socketPath)
        _ = socketPath.withCString { unlink($0) }
      }
    } catch {
      Logger(subsystem: "com.gumpw.codans.runtime", category: "runtime.session.coordinator")
        .error(
          "Forget all sessions failed to persist: \(String(describing: error), privacy: .public)"
        )
    }
  }

  /// Flushes all pending debounced writes. Called by `applicationWillTerminate`.
  /// Any debounced write that hasn't landed within 500 ms of quit would
  /// otherwise be dropped; each store below has its own debounce, so we
  /// drain them explicitly here.
  ///
  /// The pane-daemon disposition (detach / snapshot / kill) is handled upstream by
  /// `AppDelegate.applicationShouldTerminate(_:)` so it can pause for the quit
  /// confirmation dialog. By the time this runs the daemons are already in their
  /// chosen post-quit state; we only flush the remaining persisted-state stores here.
  func flushAllPersistedState() {
    // Cancel notification background Tasks first so none can race the
    // final flush by mutating store state mid-write.
    notificationDetectorTask?.cancel()
    dockBadgerTask?.cancel()
    focusReadMarkerTask?.cancel()
    orphanSweepTask?.cancel()
    agentStateFocusTask?.cancel()
    // Drop the observation tokens explicitly so a `didBecomeActive`
    // arriving mid-shutdown cannot wake the coordinator on a half-torn-down
    // settings reader.
    notificationSettingsObserverToken?.cancel()
    notificationSettingsObserverToken = nil
    didBecomeActiveObserverToken?.cancel()
    didBecomeActiveObserverToken = nil
    worktreeHeadWatcherSyncTask?.cancel()
    worktreeHeadWatcher.stopAll()
    worktreeWorkingTreeWatcherSyncTask?.cancel()
    worktreeWorkingTreeWatcher.stopAll()

    settingsStore.flush()
    shortcutsStore.flush()
    notificationStore.flush()
    catalogStore.flushPending()
    // Safety net for the SessionStore: the canonical quit path calls
    // `detachAllForQuit` → `coordinator.replace` → `saveNow` which already
    // cancels any pending write. This handles the edge case where
    // termination skips the lifecycle hook (e.g. an unrecoverable error
    // path tears the app down directly) and a recordLive timer is still
    // armed. No-op when nothing is pending.
    sessionCoordinator?.flushPending()
  }

  /// Project the live `Catalog` plus `lastFocusedPane` lookup into a
  /// `FocusState` for `RollupIndex.compute`. Reads:
  /// - active project = `selectedProjectID`
  /// - active worktree = the active project's `selectedWorktreeID`
  /// - active tab = the active worktree's `selectedTabID`
  /// - focused pane = `lastFocusedPane(activeTabID)`
  /// - expanded projects = `Project.isExpanded` filtered to true
  static func focusState(
    from catalog: Catalog,
    lastFocusedPane: @MainActor (TabID) -> PaneID?
  ) -> RollupFocusState {
    let activeProject = catalog.projects.first(where: { $0.id == catalog.selectedProjectID })
    let activeWorktree = activeProject?.worktrees.first(where: { $0.id == activeProject?.selectedWorktreeID })
    let activeTab = activeWorktree?.tabs.first(where: { $0.id == activeWorktree?.selectedTabID })
    let focusedPane = activeTab.map { lastFocusedPane($0.id) } ?? nil
    let expanded = Set(catalog.projects.filter(\.isExpanded).map(\.id))

    return RollupFocusState(
      focusedPaneID: focusedPane,
      activeTabID: activeTab?.id,
      activeWorktreeID: activeWorktree?.id,
      activeProjectID: activeProject?.id,
      expandedProjectIDs: expanded
    )
  }

  /// Long-running read marker: every time the user focuses a different
  /// pane, mark its unread entries read. Drives off the same Observation
  /// re-arming pattern as the Dock badge mirror — each loop iteration
  /// reads the current focused pane id and re-arms a tracker that fires
  /// on any catalog mutation that could change that id (selectedProjectID
  /// / selectedWorktreeID / selectedTabID / lastFocusedPane).
  @MainActor
  private static func observeFocusedPaneForRead(
    catalog: @escaping @MainActor () -> Catalog,
    lastFocusedPane: @escaping @MainActor (TabID) -> PaneID?,
    store: NotificationStore
  ) async {
    while !Task.isCancelled {
      if let paneID = currentlyFocusedPane(catalog: catalog(), lastFocusedPane: lastFocusedPane) {
        store.markReadForPane(paneID)
      }
      let stream = AsyncStream<Void> { continuation in
        withObservationTracking {
          // Touch every catalog field the focused-pane composition reads
          // so any one of them mutating fires onChange.
          let snap = catalog()
          _ = snap.selectedProjectID
          for project in snap.projects {
            _ = project.selectedWorktreeID
            for worktree in project.worktrees {
              _ = worktree.selectedTabID
            }
          }
          // lastFocusedPane is read off HierarchyManager, which is
          // @Observable upstream — touching the resolved id here keeps
          // its observation registered alongside the catalog reads.
          if let activeProjectID = snap.selectedProjectID,
            let project = snap.projects.first(where: { $0.id == activeProjectID }),
            let worktreeID = project.selectedWorktreeID,
            let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
            let tabID = worktree.selectedTabID
          {
            _ = lastFocusedPane(tabID)
          }
        } onChange: {
          Task { @MainActor [continuation] in
            continuation.yield(())
          }
        }
        continuation.onTermination = { _ in }
      }
      for await _ in stream {
        break
      }
    }
  }

  /// Returns the single globally-focused pane id, computed the same way
  /// `NotificationDetector.globallyFocusedPane` does. Kept here so both
  /// the detector (drop-on-focus) and the read marker agree on the rule.
  /// Note: app frontmost is intentionally NOT gated here — focusing a
  /// pane in the app is the user's deliberate action regardless of
  /// frontmost state, and we want a worktree-switch to clear unreads on
  /// the newly-focused pane even if the user did it via a global hotkey
  /// while another app held foreground.
  static func currentlyFocusedPane(
    catalog: Catalog,
    lastFocusedPane: @MainActor (TabID) -> PaneID?
  ) -> PaneID? {
    guard let activeProjectID = catalog.selectedProjectID,
      let project = catalog.projects.first(where: { $0.id == activeProjectID }),
      let worktreeID = project.selectedWorktreeID,
      let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
      let tabID = worktree.selectedTabID
    else { return nil }
    return lastFocusedPane(tabID)
  }

  /// Long-running sweep: marks unread entries pointing at panes that no
  /// longer exist in the catalog as read. Without this, closing a pane /
  /// tab / worktree before the user ever focuses it leaves the worktree /
  /// project roll-up bell lit until the user goes to the inbox and clears
  /// it manually. Mirrors `observeFocusedPaneForRead`'s re-arming pump:
  /// the first iteration runs the sweep against the boot catalog (catches
  /// stale entries inherited from prior launches), then re-arms an
  /// Observation tracker on every pane / tab / worktree / project field
  /// whose mutation could remove a pane id.
  ///
  /// Keyed on `visiblePaneIDs()`, not `allPaneIDs()`, so an archived
  /// Worktree's panes count as gone — the same choice the AgentState
  /// reconcile makes. Archive is soft-hide: the Panes stay in the catalog,
  /// so an unread entry from one used to survive here and keep the
  /// collapsed project's bell (and the status-bar / Dock badge) lit while
  /// the sidebar rendered no row the user could open to clear it. The
  /// trade is that unarchiving does not resurrect those unreads.
  @MainActor
  private static func observeOrphanUnreadsSweep(
    catalog: @escaping @MainActor () -> Catalog,
    store: NotificationStore
  ) async {
    while !Task.isCancelled {
      store.sweepOrphanUnreads(livePaneIDs: catalog().visiblePaneIDs())
      let stream = AsyncStream<Void> { continuation in
        withObservationTracking {
          let snap = catalog()
          // Touch every level whose mutation can remove a pane id from
          // the catalog so any close / remove path fires onChange.
          for project in snap.projects {
            for worktree in project.worktrees {
              for tab in worktree.tabs {
                for pane in tab.panes {
                  _ = pane.id
                }
              }
            }
          }
        } onChange: {
          Task { @MainActor [continuation] in
            continuation.yield(())
          }
        }
        continuation.onTermination = { _ in }
      }
      for await _ in stream {
        break
      }
    }
  }

  /// Reduce a launch-time sweep's per-pane state map to the restore queue
  /// the engine consumes during bring-up. Only `.snapshot(url)` states
  /// represent a pane to restore (a `<paneID>.snap` survives on disk with
  /// no live daemon); `.alive`/`.dead` states are not restores and are
  /// dropped. `internal` (not `private`) so `@testable` tests can exercise
  /// the derivation directly. See `bootstrapSessionStack`.
  static func derivePendingRestores(
    from states: [PaneID: SessionState]
  ) -> [PaneID: URL] {
    states.reduce(into: [PaneID: URL]()) { result, entry in
      if case .snapshot(let url) = entry.value {
        result[entry.key] = url
      }
    }
  }

  /// `(worktreeID → path)` for every non-archived Worktree across all
  /// Projects. Drives both `WorktreeHeadWatcher.setWorktrees(_:)` and
  /// `WorktreeWorkingTreeWatcher.setWorktrees(_:)` (identical watched set);
  /// archived rows are filtered out because they are hidden in the sidebar
  /// and any on-disk change in their path is irrelevant until the user
  /// un-archives. Path is the canonical form already stored on the row.
  fileprivate static func headWatcherPairs(from catalog: Catalog) -> [WorktreeID: String] {
    var pairs: [WorktreeID: String] = [:]
    for project in catalog.projects {
      for worktree in project.worktrees where !worktree.archived {
        pairs[worktree.id] = worktree.path
      }
    }
    return pairs
  }

  /// Starts the long-running mirror task that keeps the `WorktreeHeadWatcher`'s
  /// worktree set in sync with the catalog. Sample BEFORE arming the next
  /// `withObservationTracking` so any mutation between sync and re-arm is
  /// caught on the pre-arm pass — same race-closing pattern the selection
  /// stream in `HierarchyClient.makeSelectionStream` uses. Factored out of
  /// `bringUp` to keep that method under the lint limit.
  private func startHeadWatcherSync() {
    worktreeHeadWatcherSyncTask?.cancel()
    let manager = hierarchyManager
    let watcher = worktreeHeadWatcher
    let statusMonitor = worktreeStatusMonitor
    let diffMonitor = worktreeLocalDiffMonitor
    worktreeHeadWatcherSyncTask = Task { @MainActor in
      var last: [WorktreeID: String] = [:]
      while !Task.isCancelled {
        let current = Self.headWatcherPairs(from: manager.catalog)
        if current != last {
          watcher.setWorktrees(current.map { (id: $0.key, path: $0.value) })
          // The two sidebar monitors cache lazily and had no removal path,
          // so a removed or archived Worktree kept its chip data forever.
          // This projection is already exactly the live, non-archived set.
          let live = Set(current.keys)
          statusMonitor.retain(liveWorktreeIDs: live)
          diffMonitor.retain(liveWorktreeIDs: live)
          last = current
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          withObservationTracking {
            _ = Self.headWatcherPairs(from: manager.catalog)
          } onChange: {
            cont.resume()
          }
        }
      }
    }
  }

  /// Mirror task that keeps `WorktreeWorkingTreeWatcher`'s set in sync with
  /// the catalog, reusing the same non-archived `(id → path)` projection as
  /// the HEAD watcher. Same pre-arm-sample / re-arm pattern as
  /// `startHeadWatcherSync` so a mutation between sync and re-arm is caught.
  private func startWorkingTreeWatcherSync() {
    worktreeWorkingTreeWatcherSyncTask?.cancel()
    let manager = hierarchyManager
    let watcher = worktreeWorkingTreeWatcher
    worktreeWorkingTreeWatcherSyncTask = Task { @MainActor in
      var last: [WorktreeID: String] = [:]
      while !Task.isCancelled {
        let current = Self.headWatcherPairs(from: manager.catalog)
        if current != last {
          watcher.setWorktrees(current.map { (id: $0.key, path: $0.value) })
          last = current
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          withObservationTracking {
            _ = Self.headWatcherPairs(from: manager.catalog)
          } onChange: {
            cont.resume()
          }
        }
      }
    }
  }

  /// Long-running mirror: routes every `store.unreadCount` change through
  /// `coordinator.recomputeDockBadge()` so the badge honours the
  /// `inAppEnabled` + `dockBadgeEnabled` gates regardless of which path
  /// mutated the inbox (detector dispatch, `markRead`, `markAllRead`,
  /// `sweepOrphanUnreads`). Each loop iteration recomputes before re-arming
  /// `withObservationTracking` so a burst of mutations between the previous
  /// `onChange` fire and the next arm settles to the final value rather
  /// than a stale one. Returns when the surrounding Task is cancelled or
  /// when the coordinator is deallocated.
  @MainActor
  private static func observeDockBadge(
    store: NotificationStore,
    coordinator: NotificationCoordinator?
  ) async {
    while !Task.isCancelled {
      guard let coordinator else { return }
      coordinator.recomputeDockBadge()
      let stream = AsyncStream<Void> { continuation in
        withObservationTracking {
          _ = store.unreadCount
        } onChange: {
          Task { @MainActor [continuation] in
            continuation.yield(())
          }
        }
        continuation.onTermination = { _ in }
      }
      for await _ in stream {
        break
      }
    }
  }

  /// Build the binder + registry, install the five fan-out wires, kick the
  /// drain. Extracted from `startNotificationObservers` so that function
  /// stays under the lint body-length budget. `@discardableResult` so the
  /// call site doesn't have to acknowledge the binder.
  @discardableResult
  private func startAgentStateObservers(
    manager: HierarchyManager,
    engine: TerminalEngine,
    hierarchy: HierarchyClient,
    detector: NotificationDetector,
    keystrokeTracker: PaneKeyboardActivityTracker
  ) -> AgentBinder {
    // AgentStateStore is the @Observable state machine the badge +
    // popover bind to. Four wires feed it:
    //   1. terminal events  → onTerminalEvent (drain loop below)
    //   2. keystrokes       → onPaneKeyboardActivity (tracker.onActivity)
    //   3. focus changes    → onPaneFocused (observation pump)
    //   4. agent bind/unbind→ onAgentBound / onAgentUnbound (binder handlers)
    let registry = AgentStateStore(
      focusedPane: { [weak manager] in
        guard let manager else { return nil }
        return Self.currentlyFocusedPane(
          catalog: manager.catalog,
          lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) }
        )
      }
    )
    self.agentStateStore = registry
    // Pre-seed the registry from the last quit's agent snapshot so a
    // resumed working/blocked agent surfaces immediately instead of
    // waiting for the first live viewport. Each restored record is gated on
    // a direct daemon-socket probe so we never restore a phantom badge for
    // an agent whose daemon died between launches.
    Self.seedRestoredAgents(
      coordinator: self.sessionCoordinator,
      registry: registry,
      knownLiveness: self.sessionSweepLiveness
    )
    // The snapshot is keyed on daemon liveness, not catalog membership, so it
    // can carry a pane whose Project / Worktree was removed while its daemon
    // outlived the removal. Such an entry resolves to nothing and renders as
    // an em-dash ghost row. The drain loop only reconciles on the next
    // structural mutation, which may never come in a quiet session — sweep
    // the seed against the catalog immediately.
    registry.reconcileMembership(livePaneIDs: manager.catalog.visiblePaneIDs())
    // Agent bindings are runtime-only: HierarchyManager.clearAgentBindings
    // wipes `Pane.agentKind` / `Pane.agentSessionID` at launch so a dead
    // pty child from the previous session can't haunt the panel. The
    // registry refills from AgentBinder events as the user runs agents in
    // this session; the seed above only nudges the UI into the right
    // initial state until the next event lands.
    let binder = AgentBinder(
      client: hierarchy,
      currentAgentKind: { [weak manager] paneID in
        manager?.catalog.pane(paneID)?.agentKind
      },
      agentBoundHandler: { [weak registry] paneID, kind, sessionID, assumeUserInputSeen in
        registry?.onAgentBound(
          paneID,
          kind: kind,
          sessionID: sessionID,
          assumeUserInputSeen: assumeUserInputSeen
        )
      },
      agentUnboundHandler: { [weak registry] paneID in
        registry?.onAgentUnbound(paneID)
      }
    )
    self.agentBinder = binder
    // Wire 3: keystroke fan-out. The detector continues to read
    // `snapshot()` per-event; the new `onActivity` callback fires on
    // every recorded keystroke so the registry can clear waiting-for-
    // input promptly. Both consumers stay decoupled from each other.
    keystrokeTracker.onActivity = { [weak registry] paneID in
      registry?.onPaneKeyboardActivity(paneID)
    }
    let detectorEvents = engine.events()
    self.notificationDetectorTask = Task { @MainActor in
      for await event in detectorEvents {
        await detector.handle(event)
        if case .hierarchyMutated(let scope) = event, scope != .selection, scope != .tags {
          // Same backstop, same reason as the binder and registry below —
          // the detector's caches are cleared only by `.paneExited` and its
          // siblings, which the suspend-based teardown paths never emit.
          detector.reconcileMembership(livePaneIDs: manager.catalog.visiblePaneIDs())
        }
        Self.dispatchToAgentBinder(
          event: event,
          binder: binder,
          catalog: { manager.catalog }
        )
        Self.dispatchToAgentStateStore(
          event: event,
          registry: registry,
          catalog: { manager.catalog }
        )
      }
    }
    // Wire 4: focus tracker. Same re-arming observation pump pattern as
    // `observeFocusedPaneForRead` — fire `onPaneFocused` whenever the
    // globally-focused pane id changes.
    self.agentStateFocusTask = Task { @MainActor in
      await Self.observeFocusedPaneForRegistry(
        catalog: { manager.catalog },
        lastFocusedPane: { tabID in manager.lastFocusedPane(in: tabID) },
        registry: registry
      )
    }
    return binder
  }

  /// Drain-loop branch that feeds terminal events into `AgentStateStore`.
  ///
  /// On structural mutations it also reconciles the registry against the
  /// *visible* catalog membership: a worktree / project teardown can remove a
  /// pane without delivering a per-pane teardown event to the store, and a
  /// worktree archive (soft-hide) kills its panes' daemons while keeping the
  /// Panes in the catalog — both leave a bound entry that resolves to nothing
  /// (or to a hidden worktree) and renders an em-dash ghost row (and is
  /// re-persisted / re-seeded across launches). Reconciling against
  /// `visiblePaneIDs()` — not `allPaneIDs()` — is what retires an archived
  /// worktree's agent rows, since archived panes still live in the catalog.
  /// `selection` and `tags` scopes never change pane membership, so they skip
  /// the catalog walk to keep the hot selection path cheap.
  @MainActor
  private static func dispatchToAgentStateStore(
    event: TerminalEvent,
    registry: AgentStateStore,
    catalog: @MainActor () -> Catalog
  ) {
    registry.onTerminalEvent(event)
    if case .hierarchyMutated(let scope) = event, scope != .selection, scope != .tags {
      registry.reconcileMembership(livePaneIDs: catalog().visiblePaneIDs())
    }
  }

  /// Filter the previous quit's agent snapshot through a liveness check
  /// and hand the survivors to `AgentStateStore.seedRestored`.
  ///
  /// Liveness is keyed on the pane's zmx daemon, not the agent process.
  /// On the External-backend branch the agent runs inside the daemon's PTY
  /// (it is a child of the daemon's shell), and `PaneSurface` cannot read a
  /// foreground PID, so the captured `record.pid` is always `0` — a PID
  /// liveness check is useless here. The keepRunning quit path also persists
  /// `sessions: [:]` (resume reattaches from the Pane list, not the socket
  /// catalog), so `coordinator.catalog.sessions` is empty at this point and
  /// cannot be used to tell which daemons survived. We instead probe each
  /// restored pane's control socket directly via `SessionReaper.isDaemonAlive`
  /// — a reachable socket means the daemon, and the agent inside its PTY, is
  /// still alive. Agents whose daemon did not survive are dropped, as are
  /// unknown enum raws (a future build's `kindRaw` / `stateRaw`).
  @MainActor
  private static func seedRestoredAgents(
    coordinator: SessionCoordinator?,
    registry: AgentStateStore,
    knownLiveness: [PaneID: Bool] = [:]
  ) {
    guard let coordinator else { return }
    let restored = coordinator.restoredAgents
    guard !restored.isEmpty else { return }
    let seeds = selectAgentSeeds(
      restored: restored,
      knownLiveness: knownLiveness,
      isDaemonAlive: { SessionReaper.isDaemonAlive(paneID: $0) }
    )
    registry.seedRestored(seeds)
  }

  /// Collapse the launch sweep's per-pane `SessionState` into a boolean
  /// liveness map for `seedRestoredAgents`. Only `.alive` counts as a live
  /// daemon: `.dead` rows were pruned (possibly kill-recycled by the sweep),
  /// and `.snapshot` panes have no running daemon (they cold-restore from a
  /// `.snap` on next attach), so an agent badge must not be seeded for
  /// either — matching a direct `isDaemonAlive` probe of the same socket.
  static func deriveLiveness(from states: [PaneID: SessionState]) -> [PaneID: Bool] {
    states.mapValues { state in
      if case .alive = state { return true }
      return false
    }
  }

  /// Pure seed-selection policy extracted from `seedRestoredAgents` so the
  /// liveness + enum-decoding gates are unit-testable without a live socket.
  /// Keeps a restored record only when its daemon answers `isDaemonAlive`
  /// and both enum raws still decode in this build.
  static func selectAgentSeeds(
    restored: [PaneID: PersistedAgentRecord],
    knownLiveness: [PaneID: Bool] = [:],
    isDaemonAlive: (PaneID) -> Bool
  ) -> [(paneID: PaneID, kind: AgentKind, state: AgentStateStore.AgentRuntimeState)] {
    var seeds: [(paneID: PaneID, kind: AgentKind, state: AgentStateStore.AgentRuntimeState)] = []
    seeds.reserveCapacity(restored.count)
    for (paneID, record) in restored {
      // Reuse the launch sweep's verdict when it covered this pane; only
      // probe the socket directly for panes the sweep never saw (empty
      // `knownLiveness` on the keepRunning / no-resume paths).
      let alive = knownLiveness[paneID] ?? isDaemonAlive(paneID)
      guard alive else { continue }
      guard
        let kind = AgentKind(rawValue: record.kindRaw),
        let state = AgentStateStore.AgentRuntimeState(rawValue: record.stateRaw)
      else { continue }
      seeds.append((paneID: paneID, kind: kind, state: state))
    }
    return seeds
  }

  /// Long-running focus observer for `AgentStateStore`. Same re-arming
  /// `withObservationTracking` pump as
  /// `observeFocusedPaneForRead`: read the globally-focused pane (via
  /// `currentlyFocusedPane`), forward to `registry.onPaneFocused`
  /// whenever the id changes, then re-arm against the catalog fields
  /// whose mutation could shift focus.
  @MainActor
  private static func observeFocusedPaneForRegistry(
    catalog: @escaping @MainActor () -> Catalog,
    lastFocusedPane: @escaping @MainActor (TabID) -> PaneID?,
    registry: AgentStateStore
  ) async {
    var last: PaneID?
    while !Task.isCancelled {
      let current = currentlyFocusedPane(catalog: catalog(), lastFocusedPane: lastFocusedPane)
      if current != last, let current {
        registry.onPaneFocused(current)
      }
      last = current
      let stream = AsyncStream<Void> { continuation in
        withObservationTracking {
          let snap = catalog()
          _ = snap.selectedProjectID
          for project in snap.projects {
            _ = project.selectedWorktreeID
            for worktree in project.worktrees {
              _ = worktree.selectedTabID
            }
          }
          if let activeProjectID = snap.selectedProjectID,
            let project = snap.projects.first(where: { $0.id == activeProjectID }),
            let worktreeID = project.selectedWorktreeID,
            let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
            let tabID = worktree.selectedTabID
          {
            _ = lastFocusedPane(tabID)
          }
        } onChange: {
          Task { @MainActor [continuation] in
            continuation.yield(())
          }
        }
        continuation.onTermination = { _ in }
      }
      for await _ in stream {
        break
      }
    }
  }

  /// Route the engine event stream through `AgentBinder`. Lives next to
  /// `NotificationDetector.handle` (same drain loop, same MainActor context)
  /// so the binder sees foreground jobs and lifecycle teardown without
  /// opening a second long-lived Task on the events stream.
  @MainActor
  private static func dispatchToAgentBinder(
    event: TerminalEvent,
    binder: AgentBinder,
    catalog: @MainActor () -> Catalog
  ) {
    switch event {
    case .foregroundJobChanged(let paneID, let job):
      binder.consider(paneID: paneID, trigger: .foregroundJobChanged(job))
    case .paneExited(let paneID, _, _),
      .paneCrashed(let paneID, _),
      .paneClosedByTab(let paneID, _):
      binder.unbind(paneID)
    case .hierarchyMutated(let scope) where scope != .selection && scope != .tags:
      // Same reconcile the AgentState registry runs, for the same reason —
      // see `AgentBinder.reconcileMembership`. Keyed on `visiblePaneIDs()`
      // so an archived worktree's panes count as gone: that is what lets a
      // later unarchive re-materialize the binding.
      binder.reconcileMembership(livePaneIDs: catalog().visiblePaneIDs())
    default:
      break
    }
  }
}

/// Adapter: lets `HierarchyManager` call back into the engine for
/// lazy surface creation / teardown. `engine` is attached after the
/// manager is constructed to break the circular dependency.
@MainActor
final class GhosttyBackedHierarchyRuntime: HierarchyRuntime {
  private weak var engine: TerminalEngine?

  func attach(engine: TerminalEngine) {
    self.engine = engine
  }

  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) async throws {
    _ = try await engine?.ensureSurface(for: pane, in: worktree, env: env)
  }

  func closeSurface(for paneID: PaneID) {
    engine?.closeSurface(for: paneID)
  }

  func suspendSurface(for paneID: PaneID) {
    engine?.suspendSurface(for: paneID)
  }

  func announceHierarchyMutated() {
    engine?.emit(.hierarchyMutated(.catalog))
  }

  func hasSurface(for paneID: PaneID) -> Bool {
    engine?.hasSurface(for: paneID) ?? false
  }

  func currentWorkingDirectory(for paneID: PaneID) -> String? {
    engine?.currentWorkingDirectory(for: paneID)
  }

  func focusSurfaceView(for paneID: PaneID) {
    engine?.focusSurfaceView(for: paneID)
  }
}

@MainActor
final class TerminalInputSink: TerminalHandlers.InputSink {
  private weak var engine: TerminalEngine?
  /// Called once per dispatched input event so the sidebar's "active
  /// first" sort can bump `Project.lastActiveAt` on the pane's host
  /// project. Optional so previews / tests without a hierarchy manager
  /// wired can drop it.
  private let onPaneInput: (@MainActor (PaneID) -> Void)?

  init(engine: TerminalEngine, onPaneInput: (@MainActor (PaneID) -> Void)? = nil) {
    self.engine = engine
    self.onPaneInput = onPaneInput
  }

  func sendInput(paneID: PaneID, text: String) -> Bool {
    guard let surface = engine?.ghosttyRuntime?.surface(for: paneID) else { return false }
    surface.sendInput(text)
    // Empty-string writes (focus probes, etc.) shouldn't count as
    // user activity for the sidebar's "active first" sort.
    if !text.isEmpty {
      onPaneInput?(paneID)
    }
    return true
  }

  func sendKey(paneID: PaneID, key: IPC.TerminalNamedKey) -> Bool {
    guard let surface = engine?.ghosttyRuntime?.surface(for: paneID) else { return false }
    surface.sendNamedKey(key)
    onPaneInput?(paneID)
    return true
  }

  func sendRawBytes(paneID: PaneID, bytes: [UInt8]) -> Bool {
    guard let surface = engine?.ghosttyRuntime?.surface(for: paneID) else { return false }
    surface.sendRawBytes(bytes)
    if !bytes.isEmpty {
      onPaneInput?(paneID)
    }
    return true
  }

  func fanOut(scope: IPC.BroadcastScope, text: String, catalog: Catalog) -> Int {
    paneIDs(matching: scope, in: catalog)
      .reduce(into: 0) { count, paneID in
        if sendInput(paneID: paneID, text: text) {
          count += 1
        }
      }
  }

  func readText(paneID: PaneID, extent: TerminalHandlers.ReadExtent) -> String? {
    guard let surface = engine?.ghosttyRuntime?.surface(for: paneID) else { return nil }
    switch extent {
    case .viewport:
      return surface.readText(.viewport)
    case .screen:
      return surface.readText(.screen)
    case .selection:
      return surface.readSelection()
    }
  }

  func resetPane(paneID: PaneID) -> Bool {
    guard let surface = engine?.ghosttyRuntime?.surface(for: paneID) else { return false }
    surface.resetTerminal()
    return true
  }

  private func paneIDs(matching scope: IPC.BroadcastScope, in catalog: Catalog) -> [PaneID] {
    switch scope.kind {
    case .tab:
      guard let id = UUID(uuidString: scope.target).map(TabID.init(raw:)) else { return [] }
      return catalog.projects
        .flatMap(\.worktrees)
        .flatMap(\.tabs)
        .first(where: { $0.id == id })?
        .panes
        .map(\.id) ?? []
    case .worktree:
      guard let id = UUID(uuidString: scope.target).map(WorktreeID.init(raw:)) else { return [] }
      return Array(catalog.paneIDs(inWorktree: id))
    case .label:
      return catalog.projects
        .flatMap(\.worktrees)
        .flatMap(\.tabs)
        .flatMap(\.panes)
        .filter { $0.labels.contains(scope.target) }
        .map(\.id)
    }
  }
}
