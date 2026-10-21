import AppKit
import CodansCore
import Foundation
import os.log

/// Public-facing façade that composes `CatalogStore`, `HierarchyManager`, and
/// `GhosttyRuntime` behind a fan-out event stream. Feature code (TCA clients,
/// hook runner, notifications) subscribes via `events()` and mutates state
/// through `hierarchy`. Direct access to `GhosttyRuntime` or `PaneSurface`
/// objects is intentionally not exposed.
///
/// Lifecycle events (`paneCreated`, `paneReady`, `paneExited`,
/// `paneCrashed`, `tabActivated`, `tabAutoClosed`, `worktreeActivated`,
/// `hierarchyMutated`) are delivered with a large per-subscriber buffer
/// because drops cause persistence and UI desync that can't be recovered.
/// Output events (`paneOutput`, `paneIdle`) are delivered with a small
/// `.bufferingNewest` policy — scrollback retains history, so dropping
/// coalesced batches under consumer backpressure is safe.
@MainActor
final class TerminalEngine {
  struct CrashPolicy: Equatable, Sendable {
    var maxCrashesInWindow: Int = 3
    var window: TimeInterval = 30
    static let `default` = CrashPolicy()
  }

  /// Per-subscriber event fan-out. Each `events()` call registers a fresh
  /// continuation. The engine broadcasts every emit to every active
  /// subscriber until they cancel or finish.
  private final class SubscriberRegistry {
    struct Subscriber: Identifiable {
      let id: UUID
      let continuation: AsyncStream<TerminalEvent>.Continuation
      let lifecycleOnly: Bool
    }

    var subscribers: [Subscriber] = []

    func broadcast(_ event: TerminalEvent) {
      let isLifecycle = event.isLifecycle
      for subscriber in subscribers where isLifecycle || !subscriber.lifecycleOnly {
        subscriber.continuation.yield(event)
      }
    }

    func finishAll() {
      for subscriber in subscribers {
        subscriber.continuation.finish()
      }
      subscribers.removeAll()
    }
  }

  let hierarchy: HierarchyManager
  let store: CatalogStore
  let ghosttyRuntime: GhosttyRuntime?
  var crashPolicy: CrashPolicy = .default

  /// Continuous write-through to `sessions.json`. Set during
  /// `bootstrapSessionStack` once the coordinator is alive; nil for
  /// headless tests and for the "second-instance, no-resume" mode where
  /// the catalog lock could not be acquired. When non-nil, every fresh
  /// spawn / reattach / restore upserts a row through `recordLive`, so
  /// a crash between launches no longer leaves recently-created panes
  /// invisible to the next launch's reaper.
  var sessionCoordinator: SessionCoordinator?

  /// Snapshot-restore paths keyed by Pane, populated by `CodansApp` before
  /// bring-up and consumed exactly once in `ensureSurface`. When a pane has an
  /// entry, its first `attach` is built with `--restore-from <path>`; the entry
  /// is removed on consumption so a later bring-up of the same pane in the same
  /// session (close + reopen) gets a clean cold command with no stale restore.
  var pendingRestores: [ContentID: URL] = [:]

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.runtime", category: "runtime.session.lifecycle"
  )
  /// Remote foreground-probe diagnostics. A network-dependent poll loop must
  /// be observable: registration, per-host failures, and (at debug) tick
  /// summaries — `log stream --predicate 'category == "remote.foreground"'`.
  private static let probeLogger = Logger(
    subsystem: "com.gumpw.codans.runtime", category: "remote.foreground"
  )

  private let registry = SubscriberRegistry()
  private var outputBuffers: [ContentID: PendingOutputBuffer] = [:]
  private var crashRings: [ContentID: [Date]] = [:]
  private let foregroundJobReader: ForegroundJobReader
  private var foregroundJobPollTask: Task<Void, Never>?
  private var foregroundJobContentIDs: Set<ContentID> = []
  /// Remote (Server-project) panes and their hosts. These skip the local
  /// poller — their local foreground is permanently the `ssh` tunnel — and
  /// are sampled by the host-side foreground probe instead, which feeds the
  /// SAME snapshot / binder / viewport pipeline as local panes.
  private var remoteForegroundPanes: [ContentID: RemoteHost] = [:]
  private var remoteProbeTask: Task<Void, Never>?
  private var foregroundJobSnapshots: [ContentID: ForegroundJob] = [:]
  private var foregroundJobMisses: [ContentID: UInt8] = [:]
  private var viewportSnapshots: [ContentID: String] = [:]
  /// When each pane's active-region snapshot last changed. Drives the
  /// bounded `.paneIdle` settle nudges emitted while an agent pane is quiet
  /// (see `viewportPollOutcome`).
  private var viewportChangedAt: [ContentID: Date] = [:]
  /// OSC 7501 program status records per pane. Keyed by pane, not surface:
  /// they survive a surface reclaim and re-attach, like the session does.
  private var programStatusRecords: [ContentID: ProgramStatusRecords] = [:]
  /// Process-group → resolved foreground job cache. The poll loop hits
  /// every PGID at ≤300 ms when an agent is bound; the underlying
  /// `proc_listpids` + `proc_pidinfo` + `KERN_PROCARGS2` triad costs a
  /// handful of syscalls per group. A short TTL collapses repeated
  /// queries for the same PGID across consecutive ticks down to one
  /// real syscall round per `cacheTTL` window.
  private struct CachedForegroundJob {
    let job: ForegroundJob
    let expiresAt: Date
  }
  private var foregroundJobCache: [Int32: CachedForegroundJob] = [:]
  private static let foregroundJobCacheTTL: TimeInterval = 0.75
  private let clock: @Sendable () -> Date
  private var finished = false

  // MARK: Idle-surface reclaim

  /// Thresholds for detaching long-hidden pane surfaces; see
  /// `SurfaceReclaimPolicy`.
  var reclaimPolicy = SurfaceReclaimPolicy()
  /// App-level veto, consulted per candidate: the agent store and command
  /// queue live above the Runtime layer, so the app injects what it knows.
  var reclaimVeto: @MainActor (ContentID) -> Bool = { _ in false }
  /// Last time each registered surface was seen inside a window.
  private var lastDisplayedAt: [ContentID: Date] = [:]
  /// Panes whose surface was detached by the reclaim sweep. Their zmx daemon
  /// still runs, so a later `ensureSurface` is a re-attach, not a spawn:
  /// it must not replay `initialCommand` into the live shell.
  private(set) var reclaimedPanes: Set<ContentID> = []
  /// Size in points of each reclaimed pane's surface view when it was
  /// detached; the re-attach starts at it.
  private var reclaimedSurfaceSizes: [ContentID: CGSize] = [:]
  private var reclaimSweepTask: Task<Void, Never>?

  /// Inject a `GhosttyRuntime` for real pane surfaces, or pass `nil` for
  /// headless tests. When nil, `ensureSurface` throws.
  init(
    store: CatalogStore,
    hierarchy: HierarchyManager,
    ghosttyRuntime: GhosttyRuntime? = nil,
    foregroundJobReader: ForegroundJobReader = ForegroundJobReader(),
    clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.hierarchy = hierarchy
    self.ghosttyRuntime = ghosttyRuntime
    self.foregroundJobReader = foregroundJobReader
    self.clock = clock
    // Back-pointer so the libghostty action decoder can emit events
    // (paneInfoChanged, paneActionRequested, etc.) onto this engine's
    // stream. Weak on the runtime side; no cycle.
    ghosttyRuntime?.terminalEngine = self
  }

  // Explicit (nonisolated) deinit so the compiler emits the standard
  // nonisolated tail rather than the synthesized isolated deinit Swift 6
  // generates for `@MainActor` classes. The isolated path hops via
  // `swift_task_deinitOnExecutorMainActorBackDeploy`, which double-frees a
  // TaskLocal scope when released inside a cascading teardown — the libmalloc
  // abort fixed for PaneSurface (2bbee60), SurfaceInfo, and
  // AgentStateOrderCoordinator. Cancelling the foreground-job poller here is
  // also correct hygiene; `Task.cancel()` is nonisolated and `Task?` is
  // Sendable, so it is sound from a nonisolated deinit.
  deinit {
    foregroundJobPollTask?.cancel()
    remoteProbeTask?.cancel()
    reclaimSweepTask?.cancel()
  }

  // MARK: - Pane surface lifecycle

  nonisolated enum SurfaceError: LocalizedError, Sendable {
    case runtimeUnavailable
    case notATerminal

    var errorDescription: String? {
      switch self {
      case .runtimeUnavailable:
        return "The terminal engine is not running."
      case .notATerminal:
        return "This content is not a terminal."
      }
    }
  }

  // swiftlint:disable async_without_await
  /// Create a libghostty surface for the Content. Idempotent: if a
  /// surface is already registered for it, returns the existing one.
  /// Wires the surface's `onClose` to emit the lifecycle event + dispose
  /// buffer. `address` is where the Tab sits right now; the engine uses it
  /// for the spawn-time environment and the `.paneCreated` event, and
  /// resolves later focus questions live from the catalog, since a Tab can
  /// move to another Pane while its surface lives on.
  ///
  /// Stays `async throws` to satisfy the `HierarchyRuntime` protocol (whose
  /// other conformers await) and because every caller already `await`s it;
  /// the exec-backend bringup is synchronous now — libghostty forks the
  /// `zmx attach` child, so there is no daemon round-trip to await here.
  @discardableResult
  func ensureSurface(
    for content: ContentSnapshot,
    at address: TabAddress,
    in worktree: Worktree,
    env: [String: String] = [:],
    initialSize: CGSize? = nil
  ) async throws -> PaneSurface {
    // swiftlint:enable async_without_await
    guard let runtime = ghosttyRuntime else { throw SurfaceError.runtimeUnavailable }
    let contentID = content.id
    if let existing = runtime.surface(for: contentID) {
      return existing
    }
    guard let terminal = content.terminal else { throw SurfaceError.notATerminal }

    // Exec-backend bringup: libghostty forks `zmx attach <session>` and owns
    // the local PTY plus its sizing (it spawns the child at the surface's
    // initial size; see `GhosttySurfaceView.init`). zmx `attach` upserts —
    // it reattaches to a surviving daemon (resume) or creates a fresh one —
    // so cold start and relaunch are the
    // same invocation; there is no spawn/reattach/restore branching here.
    // `ZMX_DIR` is pinned, and its directory pre-created (zmx's own mkdir is
    // non-recursive), so the daemon socket lands where `ZmxControlClient`
    // looks for it.
    // Consume any pending snapshot-restore path exactly once and bake it into
    // the command below. `command` is built a single time and reused for BOTH
    // the initial PaneSurface attempt and the ticked retry, so the path
    // is consumed once and the retry still restores. A later ensureSurface for
    // the same Content (close + reopen) finds the map already cleared, so it
    // gets a clean cold command with no stale re-restore. Do NOT move this
    // consume into the attempt/retry block or that consume-once invariant
    // breaks.
    let restorePath = consumeRestorePath(for: contentID)
    if restorePath != nil {
      Self.logger.info(
        "zmx.restore applied content=\(contentID.raw.uuidString, privacy: .public)"
      )
    }
    // The zmx session is named after the ContentID — the session UUID —
    // so a session created before the layout change reattaches unchanged.
    let session = ZmxAttachCommand.session(for: contentID)
    // A Server-project Content runs its shell on the remote host: libghostty
    // spawns a local `zmx attach` (quit-persistence of the tunnel) wrapping an
    // SSH reconnect loop that lands in the remote worktree. The remote `cd`
    // owns the directory, so libghostty's local `working_directory` (which it
    // chdirs the ssh process into) must be a real *local* path — the remote
    // worktree path is meaningless locally. Local Contents run the user's
    // shell under `zmx attach <session>`, anchored at their own directory.
    let remoteHost = hierarchy.catalog.projects.first(where: { $0.id == address.projectID })?.remoteHost
    let launch: SurfaceLaunch
    let surfaceWorkingDirectory: String
    if let remoteHost {
      let command = RemoteSurfaceCommand.build(
        host: remoteHost,
        contentID: contentID,
        remotePath: terminal.workingDirectory,
        // A missing local zmx degrades to the bare reconnect loop (no
        // quit-persistence of the tunnel; reconnect still works).
        localZmxPath: try? PaneDaemonBringup.zmxBinaryURL().path,
        hostPersistence: true
      )
      launch = .command(command)
      surfaceWorkingDirectory = NSHomeDirectory()
    } else {
      // libghostty resolves and integrates the user's shell and runs it
      // under this wrapper (docs/design-docs/pane-shell-integration.md).
      launch = .interactive(
        wrapper: ZmxAttachCommand.wrapperArgv(
          zmxPath: try PaneDaemonBringup.zmxBinaryURL().path,
          session: session,
          restoreFrom: restorePath
        )
      )
      surfaceWorkingDirectory = terminal.workingDirectory
    }
    let zmxDir = PaneDaemonBringup.canonicalSocketDirectory()
    try? FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
    // Each Content is its own top-level zmx session, addressed by its UUID;
    // the builder pins `ZMX_DIR`, clears an inherited `ZMX_SESSION`, and
    // stamps the three ids. See `PaneEnvironment.forSurface` for why each.
    let surfaceEnv = PaneEnvironment.forSurface(env, address: address, zmxDirectory: zmxDir)

    // Start at the size of the slot that will show the Content, so a live
    // session is not resized through a placeholder width (see
    // `GhosttySurfaceView.init`). Without a slot size, a re-attach after an
    // idle reclaim falls back to the size the surface had when it was reclaimed.
    let initialSize = initialSize ?? reclaimedSurfaceSizes[contentID]
    let surface = try Self.withSurfaceInitRetry(runtime: runtime) {
      try PaneSurface(
        runtime: runtime, contentID: contentID, session: session, launch: launch,
        workingDirectory: surfaceWorkingDirectory, env: surfaceEnv, initialSize: initialSize
      )
    }
    runtime.register(pane: surface)
    let isReattach = noteSurfaceRegistered(contentID)
    // Continuous catalog write-through: record the live session so a crash
    // between launches still surfaces this Content to the next launch's
    // reaper. The socket path is derivable from the id + canonical ZMX_DIR;
    // the daemon PID is learned lazily via the control `.info` probe.
    if let coordinator = sessionCoordinator {
      coordinator.recordLive(
        Session(
          contentID: contentID,
          socketPath: ZmxControlClient.socketPath(for: contentID),
          pid: 0,
          createdAt: Date(),
          lastAttachedAt: Date(),
          command: [],
          cwd: terminal.workingDirectory,
          zmxVersion: "",
          // Stamp the live login session so the next launch's reaper can
          // tell a daemon that outlived its session apart from one still
          // in the current session. See `SessionEpoch`.
          sessionEpoch: SessionEpoch.current()
        )
      )
    }
    // Local-process introspection carries no signal for a remote Content:
    // its local foreground group is permanently the `ssh` tunnel, which the
    // classifier reads as a running command — pinning the tab / worktree busy
    // spinner forever on a session that is just sitting at the remote prompt.
    // Remote Contents are sampled by the host-side foreground probe instead
    // (`RemoteForegroundProbe`), which feeds the same binder / busy / viewport
    // pipeline with the REAL foreground job on the host.
    if let remoteHost {
      remoteForegroundPanes[contentID] = remoteHost
      remoteProcessGenerations[contentID] = UUID()
      Self.probeLogger.info(
        "register content=\(contentID.raw.uuidString.prefix(8), privacy: .public) host=\(remoteHost.authority, privacy: .public)"
      )
      startRemoteForegroundProbingIfNeeded()
    } else {
      foregroundJobContentIDs.insert(contentID)
      startForegroundJobPollingIfNeeded()
    }
    surface.onClose = { [weak self] processAlive in
      self?.handleSurfaceClose(contentID: contentID, processAlive: processAlive)
    }
    // Bridge AppKit first-responder into the catalog focus so the Worktree's
    // focused Pane tracks user clicks. Without this, click-driven focus
    // changes only update libghostty + the responder chain — the persisted
    // focus never moves and consumers like the strip's active style keep
    // reading the wrong Pane. Resolved live: the Tab may have moved.
    surface.view.onBecomeFirstResponder = { [weak self] in
      self?.surfaceBecameFirstResponder(contentID)
    }
    // Lets the view RESTORE firstResponder after a SwiftUI split/zoom rebuild
    // re-attaches it — only the focused Pane's selected Content reclaims, so
    // a freshly split Pane keeps input without siblings stealing it.
    surface.view.shouldClaimFocus = { [weak self] in
      self?.isFocusedContent(contentID) ?? false
    }
    // Right-click menu items raise PaneActionRequest values directly on the
    // view; lift them onto the engine's event stream so they reach
    // PaneActionRouterFeature through the same path as libghostty-decoded
    // intents (new_split / reset / etc.).
    surface.view.onPaneAction = { [weak self] request in
      self?.emit(.paneActionRequested(contentID, request))
    }
    // Forward the live-only `initialCommand` to the freshly spawned shell so
    // `.shellEditor` launches ("$EDITOR\n") actually run. This is the one
    // place it gets replayed when the surface comes up.
    // A re-attach after an idle reclaim reaches a shell that already ran it
    // (or a TUI that would take the text as typed input), and the Content
    // never stopped existing, so no lifecycle event either.
    if isReattach { return surface }
    if let initialCommand = terminal.initialCommand, !initialCommand.isEmpty {
      surface.sendInput(initialCommand + "\n")
    }
    emit(.paneCreated(contentID, address.tabID))
    emit(.paneReady(contentID))
    return surface
  }

  /// The registered surface for the Content, if any.
  func surface(for contentID: ContentID) -> PaneSurface? {
    ghosttyRuntime?.surface(for: contentID)
  }

  /// Whether the Content is the one keystrokes should reach: its Tab is
  /// selected in the Worktree's focused Pane.
  private func isFocusedContent(_ contentID: ContentID) -> Bool {
    guard let address = hierarchy.catalog.address(forContent: contentID) else { return false }
    return hierarchy.focusedContent(in: address.worktreeID)?.contentID == contentID
  }
  /// Dispose a pane's surface. Idempotent. Routes through
  /// `handleSurfaceClose` so the lifecycle event is emitted exactly once
  /// whether the close is user-initiated or callback-driven.
  ///
  /// Kills the daemon rather than detaching it: reaching here means the
  /// pane is being destroyed (closed by the user, or its tab/worktree is
  /// closing, or a crash-loop auto-closed the tab), so the daemon and its
  /// shell child should not survive. The app-quit path never comes through
  /// here — it goes through `SessionLifecycle.detachAllForQuit`, which
  /// decides keep-running vs. snapshot — so resume is unaffected.
  func closeSurface(for contentID: ContentID) {
    guard let surface = ghosttyRuntime?.surface(for: contentID) else {
      // Surfaces are lazy. A Pane the user never opened this session has
      // none, yet its zmx daemon is running — and every caller here is
      // deleting the Pane outright, so nothing will ever reattach. The old
      // bare `return` leaked that daemon until the next launch's
      // filesystem orphan sweep. Kill it directly through its control
      // socket, exactly as `suspendSurface` does; a missing socket is a
      // silent no-op. No `.paneExited` is emitted: there was no surface to
      // close, and the event's consumers all key off surface teardown.
      ZmxControlClient.kill(for: contentID)
      // A reclaimed pane did have a live surface this session, so its
      // per-pane state (polling, snapshots, process row) is still held and
      // its consumers expect the normal close event.
      if reclaimedPanes.contains(contentID) {
        handleSurfaceClose(contentID: contentID, processAlive: true)
      }
      return
    }
    surface.closeKillingDaemon()
    handleSurfaceClose(contentID: contentID, processAlive: true)
  }

  /// Archive teardown — see `HierarchyRuntime.suspendSurface`. Two
  /// deliberate departures from `closeSurface`:
  ///  1. The daemon is killed even with no registered surface. Surfaces are
  ///     lazy, so a backgrounded archived pane usually has none — but its
  ///     zmx daemon is still running and `closeSurface`'s `guard` would let
  ///     it leak (this is the multi-day daemon leak archive used to cause).
  ///  2. No `.paneExited` is emitted (`announce: false`). Archive is
  ///     soft-hide: the Pane must stay in the catalog for restore, and
  ///     `.paneExited` would route through `paneLifecycleExited → closePane`.
  func suspendSurface(for contentID: ContentID) {
    guard let surface = ghosttyRuntime?.surface(for: contentID) else {
      // No live surface — kill the still-running daemon directly via its
      // control socket (a missing socket is a silent no-op).
      ZmxControlClient.kill(for: contentID)
      if reclaimedPanes.contains(contentID) {
        handleSurfaceClose(contentID: contentID, processAlive: true, announce: false)
      }
      return
    }
    surface.closeKillingDaemon()
    handleSurfaceClose(contentID: contentID, processAlive: true, announce: false)
  }

  /// Whether a live surface is currently registered for the pane.
  /// Used by force-remove to size the "terminate N running processes"
  /// confirmation dialog (spec W-Q3).
  func hasSurface(for contentID: ContentID) -> Bool {
    guard let runtime = ghosttyRuntime else { return false }
    return runtime.surface(for: contentID) != nil
  }

  func currentWorkingDirectory(for contentID: ContentID) -> String? {
    guard let pwd = ghosttyRuntime?.surface(for: contentID)?.info.pwd,
      !pwd.isEmpty
    else { return nil }
    return pwd
  }

  /// Make the pane's `GhosttySurfaceView` the first responder of its
  /// window. Used for `Cmd+D` new-split focus and post-close focus
  /// transfer.
  ///
  /// Races with SwiftUI's render pass — right after `splitPane` the
  /// new pane's NSView has been created but may not yet be attached
  /// to its hosting window. `view.window` is then nil and
  /// `makeFirstResponder` silently fails. Retry with exponential
  /// backoff: 0s, 50ms, 100ms, 200ms, 400ms (capped at ~0.75s total).
  /// Safe to call when the surface or window never materialises —
  /// retries stop on their own.
  func focusSurfaceView(for contentID: ContentID) {
    focusSurfaceView(for: contentID, attempt: 0)
  }

  /// Called after a pane's surface becomes the first responder. The app
  /// injects what it does with it: focus can land on the surface after the
  /// catalog selection already moved (a sidebar click that switches tabs).
  var onSurfaceFocused: @MainActor (ContentID) -> Void = { _ in }

  private func surfaceBecameFirstResponder(_ contentID: ContentID) {
    if let address = hierarchy.catalog.address(forContent: contentID) {
      try? hierarchy.focusPane(address.paneID)
    }
    // The window records the new first responder only after
    // `becomeFirstResponder` returns, so report on the next turn.
    Task { @MainActor [weak self] in self?.onSurfaceFocused(contentID) }
  }

  /// True when keystrokes would go to `contentID` right now: the app is active
  /// and the pane's surface is the first responder of the key window.
  func isSurfaceFocused(_ contentID: ContentID) -> Bool {
    guard NSApp.isActive,
      let view = ghosttyRuntime?.surface(for: contentID)?.view,
      let window = view.window, window.isKeyWindow
    else { return false }
    return window.firstResponder === view
  }

  private func focusSurfaceView(for contentID: ContentID, attempt: Int) {
    guard attempt < 5 else { return }
    guard let runtime = ghosttyRuntime,
      let surface = runtime.surface(for: contentID)
    else { return }
    if let window = surface.view.window {
      // Reconcile libghostty focus before the AppKit firstResponder switch.
      // AppKit usually delivers `resignFirstResponder` on the outgoing view,
      // which in turn calls `set_focus(false)` on its surface — but SwiftUI
      // re-render during a split can briefly detach the old view, and on
      // that path AppKit clears firstResponder without firing resignFirst-
      // Responder. The outgoing surface then keeps its libghostty focus=true
      // and its cursor keeps blinking after the new pane opens. Force every
      // non-target surface to set_focus(false); the target gets set_focus(true)
      // via its own becomeFirstResponder below. `set_focus` is idempotent,
      // so repeats on the normal path are harmless.
      runtime.defocusAllSurfaces(except: contentID)
      if window.firstResponder !== surface.view {
        surface.view.claimFirstResponder(in: window, reason: "focusSurfaceView")
      }
      return
    }
    let delayMs: Int = attempt == 0 ? 50 : 50 << attempt
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(delayMs))
      self?.focusSurfaceView(for: contentID, attempt: attempt + 1)
    }
  }

  private func handleSurfaceClose(contentID: ContentID, processAlive: Bool, announce: Bool = true) {
    // Snapshot the surface state BEFORE unregistering so a stale registry
    // entry can't drop the lifecycle event. Unregister after emit so any
    // in-flight lookup in subscriber code still resolves the surface.
    let state = ghosttyRuntime?.surface(for: contentID)?.state ?? .ready
    disposeOutputBuffer(for: contentID)

    // `announce: false` is the archive (soft-hide) path: tear down the
    // engine's per-pane scratch but emit no lifecycle event, so the Pane is
    // not routed through `RootFeature.paneLifecycleExited → closePane` and
    // survives in the catalog for restore. The daemon was already killed by
    // the `suspendSurface` caller.
    if announce {
      switch state {
      case .crashed(let reason):
        _ = recordPaneCrash(contentID: contentID, reason: reason)
      case .exited(let code):
        emit(.paneExited(contentID, code: code, signal: nil))
      default:
        // No explicit state set by markExited/markCrashed: use processAlive
        // to distinguish user-initiated close (code 0) from child exit where
        // we lack a real exit code (code -1 as a "unknown" sentinel).
        emit(.paneExited(contentID, code: processAlive ? 0 : -1, signal: nil))
      }
    }

    ghosttyRuntime?.unregister(contentID: contentID)
    reclaimedPanes.remove(contentID)
    reclaimedSurfaceSizes.removeValue(forKey: contentID)
    lastDisplayedAt.removeValue(forKey: contentID)
    foregroundJobContentIDs.remove(contentID)
    remoteForegroundPanes.removeValue(forKey: contentID)
    remoteProcessGenerations.removeValue(forKey: contentID)
    stopRemoteForegroundProbingIfIdle()
    if let snapshot = foregroundJobSnapshots[contentID] {
      // Evict the cache entry for the closing pane's PGID so a recycled
      // group id picked up by a later pane never reads back this pane's
      // last job description.
      foregroundJobCache.removeValue(forKey: snapshot.processGroupID)
    }
    hierarchy.processRegistry.remove(contentID)
    foregroundJobSnapshots.removeValue(forKey: contentID)
    foregroundJobMisses.removeValue(forKey: contentID)
    viewportSnapshots.removeValue(forKey: contentID)
    viewportChangedAt.removeValue(forKey: contentID)
    programStatusRecords.removeValue(forKey: contentID)
    // The crash ring is the one per-pane map `recordPaneCrash` owns: it
    // appends here and clears on the auto-close / retry branches, so it must
    // survive a crash close. Every other close ends the pane for good and
    // nothing can ever append to its ring again.
    if case .crashed = state, announce {
    } else {
      crashRings.removeValue(forKey: contentID)
    }
    stopForegroundJobPollingIfIdle()
  }

  /// Remove and return the pending snapshot-restore path for a pane, if any.
  /// Consume-once: the entry is dropped on read, so a second call for the same
  /// pane (e.g. a close + reopen in the same session) returns `nil` and yields a
  /// cold command with no stale re-restore. Extracted as its own method so the
  /// consume-once mechanism is unit-testable without driving the libghostty
  /// surface path.
  func consumeRestorePath(for contentID: ContentID) -> String? {
    pendingRestores.removeValue(forKey: contentID)?.path
  }

  /// Process-group leader PID of the pane's current foreground job, or
  /// `nil` when the engine has not yet observed a job for this pane.
  /// The quit-time agent snapshot reads this so the persisted record
  /// carries a PID the next launch can pass to `kill(pid, 0)` for
  /// liveness. PGID is preferred over an individual process PID because
  /// it tracks the foreground group leader and survives parent/child
  /// turnover within the same agent invocation.
  func foregroundProcessGroupID(for contentID: ContentID) -> Int32? {
    foregroundJobSnapshots[contentID]?.processGroupID
  }

  /// Return a fresh event stream for a new subscriber. Multi-consumer safe:
  /// each call registers its own continuation.
  ///
  /// Output events (`paneOutput`, `paneIdle`) drop under subscriber
  /// backpressure via `.bufferingNewest(256)` — scrollback retains history
  /// so drops are recoverable. Lifecycle events are never dropped: the
  /// bounded policy only evicts output variants, and the broadcaster does
  /// not send output to `lifecycleOnly` subscribers.
  ///
  /// Subscribing after `finishEventStream()` has already been called
  /// immediately returns a finished stream.
  ///
  /// `onTermination` cleans up the registry slot asynchronously via a hop
  /// back to the MainActor; brief (~frame-ish) window where a cancelled
  /// subscriber still receives broadcasts — cheap guard.
  func events(lifecycleOnly: Bool = false) -> AsyncStream<TerminalEvent> {
    let id = UUID()
    return AsyncStream<TerminalEvent>(
      bufferingPolicy: .bufferingNewest(256)
    ) { continuation in
      if self.finished {
        continuation.finish()
        return
      }
      self.registry.subscribers.append(
        .init(id: id, continuation: continuation, lifecycleOnly: lifecycleOnly)
      )
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor in
          self?.registry.subscribers.removeAll { $0.id == id }
        }
      }
    }
  }

  /// Emit an event to all active subscribers. No-op after `finishEventStream`
  /// has been called; avoids use-after-finish footguns.
  func emit(_ event: TerminalEvent) {
    guard !finished else { return }
    registry.broadcast(event)
  }

  /// Feed bytes from a ghostty surface into the per-pane coalescer. Creates
  /// a buffer on first use. Output may split a UTF-8 codepoint at the 16KB
  /// buffer boundary — text consumers must buffer across batches per pane.
  func appendOutput(contentID: ContentID, bytes: Data) {
    let buffer = outputBuffers[contentID] ?? makeBuffer(for: contentID)
    buffer.append(bytes)
  }

  func flushOutput(for contentID: ContentID) {
    outputBuffers[contentID]?.flush()
  }

  /// Drop the per-pane output buffer, flushing any pending bytes first. The
  /// buffer's isolated-deinit fallback exists as a safety net, but callers
  /// should invoke this explicitly when a surface closes so bytes flush
  /// while the engine is still accepting emits.
  func disposeOutputBuffer(for contentID: ContentID) {
    outputBuffers[contentID]?.flush()
    outputBuffers.removeValue(forKey: contentID)
  }

  /// Idempotent, terminal. After calling, `emit` is a no-op and all
  /// subscribers receive `finish()`. Subsequent calls are safe.
  func finishEventStream() {
    guard !finished else { return }
    finished = true
    foregroundJobPollTask?.cancel()
    foregroundJobPollTask = nil
    reclaimSweepTask?.cancel()
    reclaimSweepTask = nil
    // Drain any pending output into the lifecycle-bound path before finishing.
    for (_, buffer) in outputBuffers {
      buffer.flush()
    }
    outputBuffers.removeAll()
    registry.finishAll()
  }

  // MARK: - Crash isolation

  enum CrashOutcome: Equatable, Sendable {
    /// Pane is still alive; UI should render a retry placeholder.
    case survived
    /// The Tab was auto-closed because the crash loop exceeded policy.
    case tabAutoClosed(TabID)
    /// Attempted to auto-close but `HierarchyManager.closeTab` threw; ring
    /// preserved so a later attempt can succeed. The message is the error's
    /// `localizedDescription` — callers needing the typed error should
    /// observe `HierarchyManager.catalog` for drift instead of re-throwing.
    case closeFailed(String)
  }

  @discardableResult
  func recordPaneCrash(
    contentID: ContentID,
    reason: String
  ) -> CrashOutcome {
    // Flush any buffered output so subscribers see the final bytes BEFORE the
    // crash event — otherwise the UI shows a stale prompt with the crash
    // overlay and consumers miss the last line of whatever the pane emitted.
    disposeOutputBuffer(for: contentID)
    emit(.paneCrashed(contentID, reason: reason))

    let now = clock()
    let cutoff = now.addingTimeInterval(-crashPolicy.window)
    var ring = crashRings[contentID, default: []].filter { $0 >= cutoff }
    ring.append(now)
    // Cap the ring so repeated crashes inside the window can't grow memory.
    if ring.count > crashPolicy.maxCrashesInWindow {
      ring = Array(ring.suffix(crashPolicy.maxCrashesInWindow))
    }
    crashRings[contentID] = ring

    guard ring.count >= crashPolicy.maxCrashesInWindow else {
      return .survived
    }

    guard let address = hierarchy.catalog.address(forContent: contentID) else {
      crashRings.removeValue(forKey: contentID)
      return .survived
    }

    do {
      try hierarchy.closeTab(address.tabID)
    } catch {
      // Preserve the ring so a retry can still close the tab.
      return .closeFailed(error.localizedDescription)
    }

    crashRings.removeValue(forKey: contentID)
    let cause: TabAutoCloseCause = .crashLoop(count: ring.count, window: crashPolicy.window)
    emit(.tabAutoClosed(address.tabID, cause: cause))
    return .tabAutoClosed(address.tabID)
  }

  /// Retry a crashed pane. Returns false when the pane no longer exists
  /// (e.g. its Tab was already auto-closed).
  @discardableResult
  func retryPane(_ contentID: ContentID) -> Bool {
    guard hierarchy.catalog.content(contentID) != nil else {
      return false
    }
    crashRings.removeValue(forKey: contentID)
    emit(.paneReady(contentID))
    return true
  }

  // MARK: - Private

  private func makeBuffer(for contentID: ContentID) -> PendingOutputBuffer {
    // The engine must outlive its output buffers. disposeOutputBuffer drops
    // the buffer while the engine is still broadcasting, so the weak capture
    // only matters as a safety net if the buffer is dropped via deinit after
    // finishEventStream — in that case emit is a no-op, bytes silently fall
    // on the floor (documented trade-off).
    let buffer = PendingOutputBuffer(contentID: contentID) { [weak self] id, data in
      self?.emit(.paneOutput(id, data))
    }
    outputBuffers[contentID] = buffer
    return buffer
  }

  private func startForegroundJobPollingIfNeeded() {
    guard foregroundJobPollTask == nil else { return }
    foregroundJobPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.pollForegroundJobs()
        let interval = self?.foregroundJobPollInterval() ?? .seconds(2)
        try? await Task.sleep(for: interval)
      }
    }
  }

  private func stopForegroundJobPollingIfIdle() {
    guard foregroundJobContentIDs.isEmpty else { return }
    foregroundJobPollTask?.cancel()
    foregroundJobPollTask = nil
  }

  private func pollForegroundJobs() {
    guard let ghosttyRuntime, !foregroundJobContentIDs.isEmpty else { return }

    var groupByPane: [ContentID: Int32] = [:]
    for contentID in foregroundJobContentIDs {
      guard let surface = ghosttyRuntime.surface(for: contentID),
        let groupID = foregroundJobReader.resolveProcessGroupID(
          preferred: surface.foregroundProcessGroupID(),
          childPID: surface.childProcessID()
        )
      else {
        continue
      }
      groupByPane[contentID] = groupID
    }

    let activeGroupIDs = Set(groupByPane.values)
    let now = clock()
    var jobsByGroup: [Int32: ForegroundJob] = [:]
    var groupIDsToQuery: Set<Int32> = []
    for groupID in activeGroupIDs {
      if let cached = foregroundJobCache[groupID], cached.expiresAt > now {
        jobsByGroup[groupID] = cached.job
      } else {
        groupIDsToQuery.insert(groupID)
      }
    }
    let freshJobs = foregroundJobReader.readJobs(processGroupIDs: groupIDsToQuery)
    let cacheUntil = now.addingTimeInterval(Self.foregroundJobCacheTTL)
    for (groupID, job) in freshJobs {
      jobsByGroup[groupID] = job
      foregroundJobCache[groupID] = CachedForegroundJob(job: job, expiresAt: cacheUntil)
    }
    // Drop cache entries for PGIDs we no longer poll — pane teardown,
    // an agent shell that respawned under a new group id, etc. The OS
    // can recycle process group ids, so retaining a stale entry beyond
    // the lifetime of its owning pane risks attributing a future
    // unrelated group to a long-departed job.
    foregroundJobCache = foregroundJobCache.filter { activeGroupIDs.contains($0.key) }

    for contentID in foregroundJobContentIDs {
      let next: ForegroundJob
      if let groupID = groupByPane[contentID], let job = jobsByGroup[groupID] {
        next = job
      } else {
        next = ForegroundJob(processGroupID: groupByPane[contentID] ?? 0, processes: [])
      }
      processForegroundSample(contentID: contentID, next: next, now: now)
    }
  }

  /// Shared per-pane tail of both foreground samplers (local poll loop and
  /// remote host probe): empty-sample hysteresis, change detection, binder
  /// delivery, and the viewport nudge.
  private func processForegroundSample(contentID: ContentID, next: ForegroundJob, now: Date) {
    if next.isEmpty, foregroundJobSnapshots[contentID] == nil {
      hierarchy.updateProcessSample(contentID: contentID, job: next, now: now)
      return
    }
    if next.isEmpty {
      let misses = min((foregroundJobMisses[contentID] ?? 0) + 1, 3)
      foregroundJobMisses[contentID] = misses
      guard misses >= 3 else { return }
    } else {
      foregroundJobMisses[contentID] = 0
    }
    hierarchy.updateProcessSample(contentID: contentID, job: next, now: now)
    dropLiveProgramStatusIfAgentGone(contentID: contentID, foregroundJob: next)
    let changed = foregroundJobSnapshots[contentID] != next
    if changed {
      foregroundJobSnapshots[contentID] = next
    }
    // Deliver `next` to the binder on a genuine change, and *also* keep
    // re-delivering an unchanged job while a bound pane's foreground has
    // settled on a non-agent program. A TUI agent holds the terminal
    // foreground for its whole lifetime, so a steady non-agent foreground
    // means the agent exited — but with change-only emission no further
    // event would ever fire to retire the now-stale binding, stranding a
    // ghost agent in the view. The re-delivery lets the binder's release
    // hysteresis run to completion; it is self-limiting because the pane
    // stops being bound once released. See `shouldRedeliverForegroundJob`.
    let paneIsBound = hierarchy.catalog.content(contentID)?.terminal?.agentKind != nil
    let foregroundIsStaleNonAgent =
      !next.isEmpty && AgentKindPatterns.classify(foregroundJob: next) == nil
    if Self.shouldRedeliverForegroundJob(
      changed: changed,
      paneIsBound: paneIsBound,
      foregroundIsStaleNonAgent: foregroundIsStaleNonAgent
    ) {
      emit(.foregroundJobChanged(contentID, next))
    }
    if let surface = ghosttyRuntime?.surface(for: contentID) {
      emitViewportIfNeeded(contentID: contentID, surface: surface, foregroundJob: next, now: now)
    }
  }

  /// `ghostty_surface_new` is observed to fail transiently — ~10
  /// consecutive failures followed by a clean success with no input
  /// change, suggesting an internal race that resolves once libghostty
  /// has ticked. One ticked retry covers the race without busy-looping;
  /// if it still fails the original `GhosttyError` (carrying a reason and
  /// a `retryable` flag) is re-thrown so external callers see actionable
  /// diagnostics.
  private static func withSurfaceInitRetry(
    runtime: GhosttyRuntime,
    _ makeSurface: () throws -> PaneSurface
  ) throws -> PaneSurface {
    do {
      return try makeSurface()
    } catch GhosttyError.surfaceInitFailed(_, let retryable) where retryable {
      runtime.tick()
      return try makeSurface()
    }
  }

  // MARK: - Idle-surface reclaim

  /// Whether the pane's surface was detached by the reclaim sweep while its
  /// daemon keeps running. Out-of-band probes (`pane.read`, `pane.info`)
  /// use this: the daemon answers them with no surface attached.
  func isReclaimed(_ contentID: ContentID) -> Bool {
    reclaimedPanes.contains(contentID)
  }

  /// Bookkeeping for a freshly registered surface. Returns whether it is a
  /// re-attach of a reclaimed pane.
  private func noteSurfaceRegistered(_ contentID: ContentID) -> Bool {
    lastDisplayedAt[contentID] = clock()
    startReclaimSweepIfNeeded()
    reclaimedSurfaceSizes.removeValue(forKey: contentID)
    return reclaimedPanes.remove(contentID) != nil
  }

  /// Detach a pane's surface but keep its zmx daemon. Frees the surface's
  /// Metal buffers and its four libghostty threads. Unlike `closeSurface`,
  /// no lifecycle event is emitted and the sampling state (foreground
  /// snapshot, process row) is kept, so the pane still looks alive to its
  /// observers; only the live poll stops until `ensureSurface` re-attaches.
  func reclaimSurface(for contentID: ContentID) {
    guard let surface = ghosttyRuntime?.surface(for: contentID) else { return }
    // Detaching ends the `zmx attach` child; make sure that cannot surface
    // as a pane exit.
    surface.onClose = nil
    reclaimedSurfaceSizes[contentID] = surface.view.bounds.size
    disposeOutputBuffer(for: contentID)
    surface.close()
    ghosttyRuntime?.unregister(contentID: contentID)
    foregroundJobContentIDs.remove(contentID)
    lastDisplayedAt.removeValue(forKey: contentID)
    reclaimedPanes.insert(contentID)
    stopForegroundJobPollingIfIdle()
    Self.logger.info(
      "surface.reclaim pane=\(contentID.raw.uuidString.prefix(8), privacy: .public)"
    )
  }

  /// One sweep: note which surfaces are on screen, then reclaim the ones the
  /// policy accepts. Returns the reclaimed panes.
  @discardableResult
  func reclaimIdleSurfaces() -> [ContentID] {
    guard let runtime = ghosttyRuntime else { return [] }
    let now = clock()
    var reclaimed: [ContentID] = []
    for surface in runtime.allLiveSurfaces() {
      let contentID = surface.contentID
      // Surfaces outside the catalog (the master terminal) are not ours to
      // manage.
      guard hierarchy.catalog.content(contentID) != nil else { continue }
      if surface.isDisplayed {
        lastDisplayedAt[contentID] = now
        continue
      }
      let hiddenSince = lastDisplayedAt[contentID] ?? now
      lastDisplayedAt[contentID] = hiddenSince
      let candidate = SurfaceReclaimPolicy.Candidate(
        hiddenFor: now.timeIntervalSince(hiddenSince),
        quietFor: now.timeIntervalSince(viewportChangedAt[contentID] ?? .distantPast),
        foregroundJob: foregroundJobSnapshots[contentID],
        isRemote: remoteForegroundPanes[contentID] != nil,
        isSurfaceReady: surface.state == .ready,
        isVetoed: reclaimVeto(contentID)
      )
      if reclaimPolicy.shouldReclaim(candidate) {
        reclaimSurface(for: contentID)
        reclaimed.append(contentID)
      }
    }
    return reclaimed
  }

  private func startReclaimSweepIfNeeded() {
    guard reclaimSweepTask == nil, !finished else { return }
    reclaimSweepTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let interval = self?.reclaimPolicy.sweepInterval else { return }
        try? await Task.sleep(for: .seconds(interval))
        guard let self, !Task.isCancelled else { return }
        self.reclaimIdleSurfaces()
      }
    }
  }

  // MARK: - Remote foreground probe

  private func startRemoteForegroundProbingIfNeeded() {
    guard remoteProbeTask == nil else { return }
    remoteProbeTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.probeRemoteForegroundJobs()
        let interval = self?.remoteProbeInterval() ?? .seconds(3)
        try? await Task.sleep(for: interval)
      }
    }
  }

  private func stopRemoteForegroundProbingIfIdle() {
    guard remoteForegroundPanes.isEmpty else { return }
    remoteProbeTask?.cancel()
    remoteProbeTask = nil
  }

  private var remoteProcessGenerations: [ContentID: UUID] = [:]

  /// One probe per host per tick, covering every remote pane on it. A failed
  /// probe (unreachable host) freezes its panes' state — no emission — so a
  /// network blip cannot release a live agent binding; empty jobs are only
  /// delivered when the host answered and genuinely reported no foreground.
  /// Process rows are cleared on failure because their liveness is unknown.
  private func probeRemoteForegroundJobs() async {
    guard !remoteForegroundPanes.isEmpty else { return }
    var panesByHost: [RemoteHost: [ContentID]] = [:]
    for (contentID, host) in remoteForegroundPanes {
      panesByHost[host, default: []].append(contentID)
    }
    for (host, contentIDs) in panesByHost {
      let generations = remoteProcessGenerations
      guard let jobs = await RemoteForegroundProbe.run(host: host) else {
        Self.probeLogger.error(
          "probe failed host=\(host.authority, privacy: .public) panes=\(contentIDs.count, privacy: .public)"
        )
        for contentID in contentIDs where generations[contentID] == remoteProcessGenerations[contentID] {
          hierarchy.suspendProcessSample(contentID: contentID, now: clock())
        }
        continue
      }
      Self.probeLogger.debug(
        "probe ok host=\(host.authority, privacy: .public) jobs=\(jobs.count, privacy: .public)"
      )
      let now = clock()
      // Re-check membership: a pane can close during the SSH await.
      for contentID in contentIDs
      where remoteForegroundPanes[contentID] != nil
        && generations[contentID] == remoteProcessGenerations[contentID]
      {
        let next = jobs[contentID.raw] ?? ForegroundJob(processGroupID: 0, processes: [])
        processForegroundSample(contentID: contentID, next: next, now: now)
      }
    }
  }

  /// Remote sampling cadence. SSH round-trips are ~2 orders costlier than
  /// the local sysctl walk, so the floors sit higher than the local poller:
  /// a bound/visible agent samples at 1s (release latency), everything else
  /// at 3s (bind latency for a freshly launched agent).
  private func remoteProbeInterval() -> Duration {
    for contentID in remoteForegroundPanes.keys {
      if hierarchy.catalog.content(contentID)?.terminal?.agentKind != nil {
        return .seconds(1)
      }
      if let job = foregroundJobSnapshots[contentID],
        AgentKindPatterns.classify(foregroundJob: job) != nil
      {
        return .seconds(1)
      }
    }
    return .seconds(3)
  }

  private func foregroundJobPollInterval() -> Duration {
    var sawRunningCommand = false
    for contentID in foregroundJobContentIDs {
      if hierarchy.catalog.content(contentID)?.terminal?.agentKind != nil {
        return .milliseconds(300)
      }
      if let job = foregroundJobSnapshots[contentID] {
        if AgentKindPatterns.classify(foregroundJob: job) != nil {
          return .milliseconds(300)
        }
        if ForegroundJobClassifier.indicatesBusyCommand(job) {
          sawRunningCommand = true
        }
      }
    }
    // A plain command is running somewhere: poll faster so the spinner
    // appears / clears promptly, but slower than agent panes. Fully idle
    // panes stay at the cheap 2s cadence.
    return sawRunningCommand ? .milliseconds(500) : .seconds(2)
  }

  private func emitViewportIfNeeded(
    contentID: ContentID,
    surface: PaneSurface,
    foregroundJob: ForegroundJob,
    now: Date
  ) {
    let hasAgentSignal =
      hierarchy.catalog.content(contentID)?.terminal?.agentKind != nil
      || AgentKindPatterns.classify(foregroundJob: foregroundJob) != nil
    // Classify against the active interaction region, not the whole viewport:
    // scrollback that happens to still be visible must not pin the agent on a
    // stale prompt/spinner. Skip the read while the agent's own program
    // status decides its state: nothing would consume the text.
    guard hasAgentSignal, !programStatusGoverns(contentID),
      let text = surface.readText(.active)
    else { return }
    switch Self.viewportPollOutcome(
      text: text,
      previous: viewportSnapshots[contentID],
      changedAt: viewportChangedAt[contentID],
      now: now
    ) {
    case .changed:
      viewportSnapshots[contentID] = text
      viewportChangedAt[contentID] = now
      emit(.paneViewportChanged(contentID, text: text))
    case .idleNudge(let duration):
      emit(.paneIdle(contentID, duration: duration))
    case .quiet:
      break
    }
  }

  // MARK: Program status (OSC 7501)

  /// Apply one OSC 7501 report to `contentID`'s records and publish the new
  /// summary when it changed. Report text is untrusted and never logged.
  func ingestProgramStatus(_ report: ProgramStatusReport, for contentID: ContentID) {
    var records = programStatusRecords[contentID] ?? ProgramStatusRecords()
    let before = records.summary
    guard records.apply(report) else { return }
    Self.logger.debug(
      "program-status pane=\(contentID.raw.uuidString, privacy: .public) state=\(report.state.rawValue, privacy: .public) kind=\(report.kind?.rawValue ?? "-", privacy: .public) app=\(report.app ?? "-", privacy: .public) child=\(!report.id.isEmpty, privacy: .public)"
    )
    storeProgramStatus(records, for: contentID, before: before)
  }

  /// Whether `contentID`'s program status decides the state of the agent
  /// bound to it. While true the screen is not read and the agent's
  /// OSC 9;4 progress is not shown as terminal activity.
  func programStatusGoverns(_ contentID: ContentID) -> Bool {
    guard let summary = programStatusRecords[contentID]?.summary else { return false }
    return summary.governs(hierarchy.catalog.content(contentID)?.terminal?.agentKind)
  }

  /// The protocol drops `working` / `blocked` records when the reporting
  /// process exits. codans keeps records only for agent panes: once the
  /// pane is unbound and its foreground is no agent, the reporting agent
  /// is gone.
  private func dropLiveProgramStatusIfAgentGone(contentID: ContentID, foregroundJob: ForegroundJob) {
    guard var records = programStatusRecords[contentID],
      hierarchy.catalog.content(contentID)?.terminal?.agentKind == nil,
      foregroundJob.isEmpty || AgentKindPatterns.classify(foregroundJob: foregroundJob) == nil
    else { return }
    let before = records.summary
    guard records.dropLiveRecords() else { return }
    storeProgramStatus(records, for: contentID, before: before)
  }

  private func storeProgramStatus(
    _ records: ProgramStatusRecords, for contentID: ContentID, before: ProgramStatusSummary?
  ) {
    programStatusRecords[contentID] = records.isEmpty ? nil : records
    let after = records.summary
    if after != before {
      emit(.paneProgramStatusChanged(contentID, after))
    }
  }

  /// How long after an agent pane's active region goes quiet we keep
  /// nudging the agent-state machine with `.paneIdle`. Sized to comfortably
  /// outlast `PaneAttentionInterpreter.agentWorkingHold` so the held
  /// `working` state always gets at least one post-hold derivation, then
  /// bounded so a long-idle agent pane stops ticking.
  static let idleNudgeWindow: TimeInterval = PaneAttentionInterpreter.agentWorkingHold * 2

  enum ViewportPollOutcome: Equatable {
    case changed
    case idleNudge(duration: TimeInterval)
    case quiet
  }

  /// Pure decision for what an agent pane's foreground-job poll should emit,
  /// given the freshly read active-region `text`, the `previous` snapshot,
  /// when that snapshot was first observed (`changedAt`), and `now`.
  ///
  /// - Changed text → `.changed`: the live cue moved, emit `paneViewportChanged`.
  /// - Unchanged within `idleNudgeWindow` → `.idleNudge`: the screen has
  ///   settled but the agent-state machine debounces a finishing agent's
  ///   `working`→`idle` transition (`agentWorkingHold`). That trailing edge
  ///   only flips on a *follow-up* derivation; once the rendered region stops
  ///   changing no further `paneViewportChanged` fires, so the held `working`
  ///   would never settle to `finished`. These bounded `.paneIdle` ticks
  ///   supply that follow-up. (Notification consumers ignore sub-30 s idle,
  ///   so this stays badge-only.)
  /// - Unchanged beyond the window → `.quiet`: stop, the badge has settled.
  static func viewportPollOutcome(
    text: String,
    previous: String?,
    changedAt: Date?,
    now: Date
  ) -> ViewportPollOutcome {
    guard previous == text else { return .changed }
    guard let changedAt else { return .quiet }
    let quiet = now.timeIntervalSince(changedAt)
    guard quiet > 0, quiet <= idleNudgeWindow else { return .quiet }
    return .idleNudge(duration: quiet)
  }

  /// Whether `pollForegroundJobs` should deliver the freshly read foreground
  /// job to the binder this tick.
  ///
  /// A genuine change always emits. Additionally, while a *bound* pane's
  /// foreground has settled on a non-agent program, the unchanged job is
  /// re-delivered so the binder's release hysteresis can retire the stale
  /// binding: a TUI agent owns the terminal foreground for its whole lifetime,
  /// so a steady non-agent foreground means the agent exited — yet with
  /// change-only emission no further event fires to signal it, leaving a ghost
  /// agent bound forever. Bounded by the binder's own miss threshold and
  /// self-limiting (the pane stops being bound once the release lands).
  static func shouldRedeliverForegroundJob(
    changed: Bool,
    paneIsBound: Bool,
    foregroundIsStaleNonAgent: Bool
  ) -> Bool {
    changed || (paneIsBound && foregroundIsStaleNonAgent)
  }
}

extension TerminalEvent {
  /// Lifecycle events must not drop under consumer backpressure — they drive
  /// persistence and TCA state machines. Output events are safe to drop
  /// because scrollback retains history.
  fileprivate var isLifecycle: Bool {
    switch self {
    case .paneOutput, .paneViewportChanged, .paneIdle, .paneInfoChanged,
      .paneProgramStatusChanged, .foregroundJobChanged:
      return false
    case .paneCreated, .paneReady, .paneExited, .paneCrashed,
      .paneClosedByTab, .tabActivated, .tabAutoClosed,
      .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      return true
    }
  }
}
