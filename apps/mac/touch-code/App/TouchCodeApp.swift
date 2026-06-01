import AppKit
import Combine
import ComposableArchitecture
import GhosttyKit
import SwiftUI
import TouchCodeCore
import TouchCodeIPC
@preconcurrency import UserNotifications
import os

@main
struct TouchCodeApp: App {
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
    // users create extras out-of-band. See docs/design-docs/project-tags.md
    // §3.8 for the close-vs-quit semantics.
    Window("TouchCode", id: TouchCodeApp.mainWindowID) {
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
          .environment(commandKeyObserver)
          .environment(\.resolvedShortcuts, appState.shortcutsStore.resolved)
        } else {
          // Initial loading state while appState.bringUp runs.
          // The view itself is intentionally cosmetic — bringUp is
          // kicked off from `.task` below, and the idempotency guard
          // (`store == nil` check inside bringUp) is load-bearing
          // because SwiftUI re-runs `.task` on scene reattach.
          AppBootstrapView()
            .frame(minWidth: 800, minHeight: 600)
            .task {
              appDelegate.appState = appState
              appState.openSettingsWindowAction = {
                openWindow(id: TouchCodeApp.settingsWindowID)
              }
              appState.bringUp()
            }
        }
      }
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
        sidebarFocus: sidebarFocusObserver
      )
      CommandGroup(replacing: .appSettings) {
        // Chord routes through the registry so a user override in Settings → Shortcuts
        // rebinds the menu item without restart. Default remains the AppKit-conventional ⌘,.
        Button("Settings…") {
          openWindow(id: TouchCodeApp.settingsWindowID)
        }
        .appKeyboardShortcut(.openSettings, in: appState.shortcutsStore.resolved)
      }
    }

    Window("Settings", id: TouchCodeApp.settingsWindowID) {
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
  /// Returns `.terminateNow` for keepRunning / snapshot so the subsequent
  /// `willTerminate` hook still fires and the remaining persisted-state flushes run.
  /// `.cancel` aborts the quit entirely.
  nonisolated func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    MainActor.assumeIsolated {
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
        if activePanes > 0 {
          lifecycle?.detachAllForQuit(action: action)
        }
        return .terminateNow
      }

      let choice = QuitConfirmationDialog.present(
        paneCount: activePanes,
        defaultAction: action
      )
      switch choice {
      case .keepRunning:
        lifecycle?.detachAllForQuit(action: .keepRunning)
        return .terminateNow
      case .snapshot:
        lifecycle?.detachAllForQuit(action: .snapshot)
        return .terminateNow
      case .cancel:
        return .terminateCancel
      }
    }
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

  /// `touch-code://focus?project=...&worktree=...&tab=...&pane=...`
  /// → `(projectID, worktreeID, tabID, paneID)`.
  nonisolated static func parseDeeplink(_ url: URL) -> InboxEntry.SourcePath? {
    guard url.scheme == "touch-code", url.host == "focus" else { return nil }
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
  /// window — touch-code is a long-lived terminal host and an inadvertent
  /// close should not tear down running panes. Re-clicking the dock icon
  /// (or `open -a touch-code`) re-shows the window.
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
  /// v1 notifications inbox owner; survives the full app lifetime so the
  /// debounced JSON write to `~/.config/touch-code/notifications.json` and
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
  /// R1: re-marks unread entries as read whenever the user focuses the
  /// pane they belong to. Observes catalog focus state via Observation
  /// re-registration; held so shutdown can cancel cleanly.
  @ObservationIgnored private var focusReadMarkerTask: Task<Void, Never>?
  /// Marks orphaned unread entries (whose source pane no longer exists in
  /// the catalog) as read. Observes the catalog's pane membership via the
  /// same re-registration pattern as the R1 marker; held so shutdown can
  /// cancel cleanly. Runs an initial sweep on first iteration to clean up
  /// entries inherited from prior launches.
  @ObservationIgnored private var orphanSweepTask: Task<Void, Never>?
  /// Live banner adapter; held so M5's Settings panel can call
  /// `requestAuthorization()` from the recovery button. Single instance
  /// per process — Settings panel reads via `@Environment` rather than
  /// spawning its own (each `init` re-runs setNotificationCategories
  /// on the shared center).
  @ObservationIgnored private(set) var osNotifier: UserNotificationsOSNotifier?
  /// M2.T2 single chokepoint: gates every detector candidate against the
  /// v1.1 settings toggles and drives the inbox + banner + dock badge in
  /// lockstep. Held so the lifetime tracks the app and so the dock-badge
  /// mirror task can call `recomputeDockBadge` on `unreadCount` changes
  /// that originate from non-coordinator paths (markRead, sweepOrphan...).
  @ObservationIgnored private(set) var notificationCoordinator: NotificationCoordinator?
  /// Active-agents T3: classifies the agent driving each pane and persists
  /// the verdict via `HierarchyClient.setPaneAgentKind`. Constructed in
  /// `startNotificationObservers` (it shares the engine-event drain with
  /// `NotificationDetector`) and dispatched from the same `for await event`
  /// loop. Long-lived for the app lifetime.
  @ObservationIgnored private(set) var agentBinder: AgentBinder?
  /// Active-agents T6: derived UI-side state machine for the badge +
  /// popover. Subscribes to four event sources (terminal events,
  /// keystrokes, focus, agent bind/unbind) wired in
  /// `startNotificationObservers`. Held long-lived so SwiftUI consumers
  /// outlive any scene reattach.
  @ObservationIgnored private(set) var agentStateStore: AgentStateStore?
  /// Long-running focus observer for AgentStateStore. Re-arms on every
  /// catalog mutation that could change the globally-focused pane and
  /// forwards new ids to `registry.onPaneFocused`. Same re-arming
  /// pattern as `observeFocusedPaneForRead`.
  @ObservationIgnored private var agentStateFocusTask: Task<Void, Never>?
  /// M5.T1 keystroke side channel: per-pane "last user keystroke at"
  /// timestamps fed into the translator's `userTypingRecently` window.
  /// Strong reference here keeps the tracker alive; the
  /// `PaneKeyboardActivityTracker.shared` weak handle exposes it to the
  /// AppKit `GhosttySurfaceView` keystroke site.
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
  /// window (spec M16).
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
  /// Per-Worktree "git status is non-clean" cache. The sidebar row's `.task(id:)`
  /// refreshes this lazily; a small dot is drawn next to the row name when dirty.
  let worktreeStatusMonitor: WorktreeStatusMonitor
  /// Per-Worktree "uncommitted edits" line counts (`git diff HEAD
  /// --shortstat`). Drives the `+N −M` chip on sidebar worktree rows
  /// regardless of PR state. Shared with the reducer via the
  /// `WorktreeLocalDiffMonitor` DependencyKey so HEAD-watcher events can
  /// invalidate the cache.
  let worktreeLocalDiffMonitor: WorktreeLocalDiffMonitor

  /// HAN-62: watches `.git/HEAD` for every catalog Worktree so terminal-
  /// driven `git checkout` inside a pane propagates to the catalog row's
  /// `branch` (and downstream PR badges) without waiting for the next
  /// app-focus event. Created here so its lifetime tracks the app and
  /// the catalog-sync task lives inside `bringUp`.
  let worktreeHeadWatcher: WorktreeHeadWatcher
  private var worktreeHeadWatcherSyncTask: Task<Void, Never>?

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
    self.settingsStore = SettingsStore()
    self.shortcutsStore = ShortcutsStore()
    self.notificationStore = NotificationStore()
    self.worktreeStatusMonitor = .live()
    self.worktreeLocalDiffMonitor = .live()
    self.worktreeHeadWatcher = WorktreeHeadWatcher()
  }

  /// Idempotent: subsequent calls while `store` is already set are no-ops.
  /// SwiftUI may re-run `.task` on scene transitions; the guard prevents
  /// rebuilding the engine + store and leaking the prior runtime.
  func bringUp() {  // swiftlint:disable:this function_body_length
    guard store == nil else { return }
    let ghostty = try? GhosttyRuntime()
    self.ghosttyRuntime = ghostty
    let engine = TerminalEngine(
      store: catalogStore,
      hierarchy: hierarchyManager,
      ghosttyRuntime: ghostty
    )
    self.terminalEngine = engine
    hierarchyRuntime.attach(engine: engine)
    bootstrapSessionStack(ghostty: ghostty, engine: engine)

    // SettingsStore loads itself (with v1→v2 migration) during `init(fileURL:)`.
    let manager = hierarchyManager
    let settings = settingsStore

    // Build the editor + hierarchy clients once so the reducer stack AND the IPC
    // handlers share the exact same live instances — avoids two parallel
    // `LiveEditorService`s with divergent settings captures.
    let editor = EditorClient.live(settings: settings)
    let hierarchy = HierarchyClient.live(
      manager: manager,
      settings: settings,
      terminalClient: .live(engine: engine)
    )
    self.editorClient = editor
    self.hierarchyClient = hierarchy

    // Notification observers + coordinator depend on `hierarchy` (the M2.T2
    // coordinator captures `HierarchyClient` so M6.T2 can call
    // `reorderWorktrees`). Construct them AFTER `hierarchy` is built but
    // BEFORE the RootStore wire-up so the detector task is already
    // draining engine events by the time the reducer is alive.
    startNotificationObservers(
      manager: manager,
      engine: engine,
      settings: settings,
      hierarchy: hierarchy
    )
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
    // git clients are already prepared in `TouchCodeApp.init`, which also
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
    self.store = Store(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.hierarchyClient = hierarchy
      $0.terminalClient = .live(engine: engine)
      // 0005 M6b critical wire: without these overrides, `EditorClient.liveValue` and
      // `SettingsWriter.liveValue` fatalError on any descendants call. Both factories close
      // over `settings` (global default + custom templates); `editorClient` additionally
      // closes over `manager` (per-Project override).
      $0.editorClient = editor
      $0.settingsWriter = .live(settings)
      $0.settingsWindowPresenter = presenter
      // Project Management: reconciler captures the live HierarchyClient so
      // `.reconcileDiscoveredWorktrees` (consumed from T-WORKTREE) flows
      // through the real manager binding. Default `now` is `Date.init`; tests
      // override with a scripted closure.
      $0.projectReconciler = ProjectReconciler(client: hierarchy)
      $0.worktreeHeadWatcher = self.worktreeHeadWatcher
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

    startHeadWatcherSync()

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
      settingsStore: settings, terminalEngine: engine
    )

    self.developerPaneDependencies = DeveloperPaneDependencies.live(
      settingsURL: Settings.defaultURL()
    )

    // Master Terminal: idempotent filesystem seed for ~/.config/touch-code/master-terminal/.
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
    // for v1; promotion to ShortcutsStore deferred until that store grows
    // a "global hotkey" scope. See ExecPlan Decision Log D3.
    //
    // Skipped if GhosttyRuntime failed to initialise — without it the panel
    // would slide in empty, with no path to recover. The same guard already
    // gates the rest of the terminal stack at line 306.
    if let ghostty {
      let controller = MasterTerminalController(runtime: ghostty)
      self.masterTerminalController = controller
      self.masterTerminalHotkey = MasterTerminalHotkey(onTrigger: { [weak controller] in
        controller?.toggle()
      })
    }
  }

  private func startNotificationObservers(
    manager: HierarchyManager,
    engine: TerminalEngine,
    settings: SettingsStore,
    hierarchy: HierarchyClient
  ) {
    let osNotifier = UserNotificationsOSNotifier()
    self.osNotifier = osNotifier

    // M2.T2 chokepoint: the coordinator gates every candidate against the
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

    // M5.T1 keystroke side channel: AppKit-side key events are recorded
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
    // Active-agents T3 + T6: build the binder and registry, install the
    // five-wire fan-out (terminal events / running set / keystrokes /
    // focus / agent bind), and start the long-running drain. Extracted
    // into a helper so this function stays under the lint body length.
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
    // M8.T1: if the inbox file was quarantined on load (a forward-version
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
  /// inside `TouchCodeApp.body`. The presenter dependency captures `self` weakly and
  /// forwards `.open()` through this closure.
  @ObservationIgnored var openSettingsWindowAction: (@MainActor () -> Void)?

  /// Wires the SocketServer so `tc` CLI can talk to the running app.
  /// Skipped under XCTest — tests build their own in-memory harnesses and
  /// binding a shared Unix socket racing parallel runs makes the runner
  /// hang.
  private func startIPC(
    hierarchy: HierarchyManager,
    editor: EditorClient,
    hierarchyClient: HierarchyClient,
    settingsStore: SettingsStore,
    terminalEngine: TerminalEngine
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
      sessionCoordinator: sessionCoordinator
    )
    let terminalHandlers = TerminalHandlers(
      sink: terminalEngine.ghosttyRuntime == nil
        ? nil
        : TerminalInputSink(
          engine: terminalEngine,
          onPaneInput: { [weak hierarchy] paneID in
            guard let manager = hierarchy,
              let projectID = manager.catalog.projectID(forPane: paneID)
            else { return }
            manager.bumpProjectActivity(projectID)
          }
        ),
      catalog: { hierarchy.catalog }
    )
    let editorHandlers = EditorHandlers(
      editor: editor,
      hierarchy: hierarchyClient,
      settings: settingsStore
    )
    let router = MethodRouter(
      systemHandlers: systemHandlers,
      hierarchyHandlers: hierarchyHandlers,
      terminalHandlers: terminalHandlers,
      editorHandlers: editorHandlers
    )
    let resolvedSocketPath = SocketPaths.resolve()
    let server = SocketServer(path: resolvedSocketPath, router: router)
    do {
      try server.start()
      self.socketServer = server
    } catch {
      // GUI launches discard stderr, so a `print` here would have been invisible.
      // Log to the unified system log so `log show --subsystem com.touch-code.ipc`
      // surfaces silent IPC bring-up failures (e.g., stale socket, prod sock
      // squatting on dev path via `$TOUCH_CODE_SOCKET_PATH`).
      Logger.ipcServer.error(
        "SocketServer bind failed at \(resolvedSocketPath, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
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
  private func bootstrapSessionStack(ghostty: GhosttyRuntime?, engine: TerminalEngine) {
    let sessionStore: SessionStore?
    do {
      sessionStore = try SessionStore(fileURL: SessionCatalog.defaultURL())
    } catch SessionStoreError.alreadyHeld {
      // Second touch-code instance: the primary process holds the
      // LOCK_EX on `sessions.json`. Degrade to "no-resume mode" —
      // every pane cold-starts, the quit-time `SessionLifecycle`
      // skips its detach/snapshot pass, and the launch-time reaper
      // is never built. Daemons spawned by this instance are still
      // `setsid`-detached, but they will not be added to the
      // catalog and therefore won't be reattached on the next launch.
      Logger(subsystem: "com.touch-code.runtime", category: "runtime.session")
        .info("sessions.json already locked by another instance; entering no-resume mode")
      self.sessionStore = nil
      return
    } catch {
      // Any other init failure (open(2) refused, flock errno that
      // isn't EWOULDBLOCK) — log and fall through to the same
      // no-resume mode. Aligns with the original `try?` semantics:
      // the worst outcome is a fresh shell per pane.
      Logger(subsystem: "com.touch-code.runtime", category: "runtime.session")
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
      Logger(subsystem: "com.touch-code.runtime", category: "runtime.session")
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
    let livePaneIDs = Self.livePaneIDs(in: hierarchyManager.catalog)
    do {
      // Pass the current hierarchy's pane ids so the reaper can kill any
      // alive daemon whose paneID no longer maps to a surface — without
      // this, an out-of-sync sessions.json vs hierarchy.json would leak
      // daemons until the 7-day stale window catches them. The returned
      // reattach states are no longer consumed: bringup re-attaches every
      // pane via `zmx attach`, so there is no per-pane reattach queue to seed.
      _ = try reaper.sweep(livePaneIDs: livePaneIDs)
    } catch {
      // A corrupt catalog or transient I/O error must not block app
      // launch — the worst outcome is a fresh shell per pane, which is
      // touch-code's pre-M2 behaviour. Log via os.Logger so a chronic
      // failure surfaces in Console.
      Logger(subsystem: "com.touch-code.runtime", category: "runtime.session.reaper")
        .error("SessionReaper.sweep failed: \(String(describing: error), privacy: .public)")
    }
    // Defense-in-depth: catch daemons whose socket files outlive both
    // the catalog and the hierarchy (e.g. crash mid-spawn before the row
    // was persisted, or daemons left by a pre-M6 build whose catalog row
    // was wiped). Runs after `sweep` so the catalog is already pruned to
    // the surviving set — anything still on disk after this point is a
    // true filesystem orphan.
    reaper.sweepFilesystemOrphans(livePaneIDs: livePaneIDs)
  }

  /// User-initiated "Forget all sessions" from Settings → General. Per
  /// the spec (R16 / AC11), the action must terminate every recorded
  /// daemon, unlink each socket, AND empty the catalog — otherwise the
  /// next `detachAllForQuit` rebuilds the catalog from the still-alive
  /// daemons (`collectLiveClients`) and effectively undoes the "forget".
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
      Logger(subsystem: "com.touch-code.runtime", category: "runtime.session.coordinator")
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
    // Drop the M2.T2 observation tokens explicitly so a `didBecomeActive`
    // arriving mid-shutdown cannot wake the coordinator on a half-torn-down
    // settings reader.
    notificationSettingsObserverToken?.cancel()
    notificationSettingsObserverToken = nil
    didBecomeActiveObserverToken?.cancel()
    didBecomeActiveObserverToken = nil
    worktreeHeadWatcherSyncTask?.cancel()
    worktreeHeadWatcher.stopAll()

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

  /// Long-running R1 marker: every time the user focuses a different
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
  /// the detector (drop-on-focus) and the R1 marker agree on the rule.
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
  @MainActor
  private static func observeOrphanUnreadsSweep(
    catalog: @escaping @MainActor () -> Catalog,
    store: NotificationStore
  ) async {
    while !Task.isCancelled {
      store.sweepOrphanUnreads(livePaneIDs: livePaneIDs(in: catalog()))
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

  /// Flatten the catalog to the set of currently-live pane ids. Used by
  /// the orphan sweep to decide which unread entries point at panes that
  /// no longer exist.
  @MainActor
  private static func livePaneIDs(in catalog: Catalog) -> Set<PaneID> {
    var ids: Set<PaneID> = []
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          for pane in tab.panes {
            ids.insert(pane.id)
          }
        }
      }
    }
    return ids
  }

  /// `(worktreeID → path)` for every non-archived Worktree across all
  /// Projects. Drives `WorktreeHeadWatcher.setWorktrees(_:)`; archived
  /// rows are filtered out because they are hidden in the sidebar and
  /// any HEAD change in their on-disk path is irrelevant until the user
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
  /// worktree set in sync with the catalog (HAN-62). Sample BEFORE arming
  /// the next `withObservationTracking` so any mutation between sync and
  /// re-arm is caught on the pre-arm pass — same race-closing pattern the
  /// selection stream in `HierarchyClient.makeSelectionStream` uses.
  /// Factored out of `bringUp` to keep that method under the lint limit.
  private func startHeadWatcherSync() {
    worktreeHeadWatcherSyncTask?.cancel()
    let manager = hierarchyManager
    let watcher = worktreeHeadWatcher
    worktreeHeadWatcherSyncTask = Task { @MainActor in
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
  /// `coordinator.recomputeDockBadge()` so the badge honours the v1.1
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

  /// Active-agents T3 + T6: build the binder + registry, install the
  /// five fan-out wires, kick the drain. Extracted from
  /// `startNotificationObservers` so that function stays under the lint
  /// body-length budget. `@discardableResult` so the call site doesn't
  /// have to acknowledge the binder.
  @discardableResult
  private func startAgentStateObservers(
    manager: HierarchyManager,
    engine: TerminalEngine,
    hierarchy: HierarchyClient,
    detector: NotificationDetector,
    keystrokeTracker: PaneKeyboardActivityTracker
  ) -> AgentBinder {
    // T6: AgentStateStore is the @Observable state machine the badge +
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
    // Pre-seed the registry from the last quit's agent snapshot (M6.T6.5).
    // Each persisted record carries the foreground PGID at capture time;
    // `kill(pid, 0)` filters out agents whose processes exited between
    // launches so we never restore a phantom "waiting for input" badge.
    Self.seedRestoredAgents(coordinator: self.sessionCoordinator, registry: registry)
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
        Self.dispatchToAgentBinder(event: event, binder: binder)
        Self.dispatchToAgentStateStore(event: event, registry: registry)
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
  @MainActor
  private static func dispatchToAgentStateStore(
    event: TerminalEvent,
    registry: AgentStateStore
  ) {
    registry.onTerminalEvent(event)
  }

  /// Filter the previous quit's agent snapshot through a liveness check
  /// and hand the survivors to `AgentStateStore.seedRestored`.
  ///
  /// Liveness is keyed on the pane's zmx daemon, not the agent process.
  /// On the External-backend branch the agent runs inside the daemon's PTY
  /// (it is a child of the daemon's shell), and `PaneSurface` cannot read a
  /// foreground PID, so the captured `record.pid` is always `0`. The reaper's
  /// launch sweep has already probed every recorded socket and left only the
  /// surviving daemons in `coordinator.catalog.sessions`; a pane present there
  /// has a reachable daemon, so the agent it hosted is alive too. Agents whose
  /// daemon did not survive are dropped. Unknown enum raws (a future build's
  /// `kindRaw` / `stateRaw`) are likewise dropped instead of failing the launch.
  @MainActor
  private static func seedRestoredAgents(
    coordinator: SessionCoordinator?,
    registry: AgentStateStore
  ) {
    guard let coordinator else { return }
    let restored = coordinator.restoredAgents
    guard !restored.isEmpty else { return }
    // Sessions that survived the reaper sweep — their daemons answered
    // `connect(2)`, so the agents running inside their PTYs are still alive.
    let aliveSessions = coordinator.catalog.sessions
    var seeds: [(paneID: PaneID, kind: AgentKind, state: AgentStateStore.AgentRuntimeState)] = []
    seeds.reserveCapacity(restored.count)
    for (paneID, record) in restored {
      guard aliveSessions[paneID.raw.uuidString] != nil else { continue }
      guard
        let kind = AgentKind(rawValue: record.kindRaw),
        let state = AgentStateStore.AgentRuntimeState(rawValue: record.stateRaw)
      else { continue }
      seeds.append((paneID: paneID, kind: kind, state: state))
    }
    registry.seedRestored(seeds)
  }

  /// Active-agents T6: long-running focus observer for `AgentStateStore`.
  /// Same re-arming `withObservationTracking` pump as
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

  /// Active-agents T3: route the engine event stream through `AgentBinder`.
  /// Lives next to `NotificationDetector.handle` (same drain loop, same
  /// MainActor context) so the binder sees foreground jobs and lifecycle teardown without
  /// opening a second long-lived Task on the events stream.
  @MainActor
  private static func dispatchToAgentBinder(
    event: TerminalEvent,
    binder: AgentBinder
  ) {
    switch event {
    case .foregroundJobChanged(let paneID, let job):
      binder.consider(paneID: paneID, trigger: .foregroundJobChanged(job))
    case .paneExited(let paneID, _, _),
      .paneCrashed(let paneID, _),
      .paneClosedByTab(let paneID, _):
      binder.unbind(paneID)
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
