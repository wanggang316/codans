import Foundation
import CodansCore
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
  var pendingRestores: [PaneID: URL] = [:]

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.runtime", category: "runtime.session.lifecycle"
  )

  private let registry = SubscriberRegistry()
  private var outputBuffers: [PaneID: PendingOutputBuffer] = [:]
  private var crashRings: [PaneID: [Date]] = [:]
  private let foregroundJobReader: ForegroundJobReader
  private var foregroundJobPollTask: Task<Void, Never>?
  private var foregroundJobPaneIDs: Set<PaneID> = []
  private var foregroundJobSnapshots: [PaneID: ForegroundJob] = [:]
  private var foregroundJobMisses: [PaneID: UInt8] = [:]
  private var viewportSnapshots: [PaneID: String] = [:]
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

  // MARK: - Pane surface lifecycle

  enum SurfaceError: Error, Sendable {
    case runtimeUnavailable
    case paneHasNoTab
  }

  // swiftlint:disable async_without_await
  /// Create a libghostty surface for the given Pane. Idempotent: if a
  /// surface is already registered for the pane, returns the existing one.
  /// Wires the surface's `onClose` to emit the lifecycle event + dispose
  /// buffer. Throws `paneHasNoTab` if the Pane isn't yet wired into a
  /// Tab — the engine uses the Tab ID in the `.paneCreated` event, so
  /// callers must add the Pane to a Tab via `HierarchyManager.openPane`
  /// (or `splitPane`) before calling this.
  ///
  /// Stays `async throws` to satisfy the `HierarchyRuntime` protocol (whose
  /// other conformers await) and because every caller already `await`s it;
  /// the exec-backend bringup is synchronous now — libghostty forks the
  /// `zmx attach` child, so there is no daemon round-trip to await here.
  @discardableResult
  func ensureSurface(
    for pane: Pane,
    in worktree: Worktree,
    env: [String: String] = [:]
  ) async throws -> PaneSurface {
    // swiftlint:enable async_without_await
    guard let runtime = ghosttyRuntime else { throw SurfaceError.runtimeUnavailable }
    if let existing = runtime.surface(for: pane.id) {
      return existing
    }
    guard let tabID = tabIDForPane(pane.id) else {
      throw SurfaceError.paneHasNoTab
    }

    // Exec-backend bringup: libghostty forks `zmx attach <session>` and owns
    // the local PTY plus its sizing (it spawns the child only once a real
    // post-layout size is known, so the shell never renders at a placeholder
    // width). zmx `attach` upserts — it reattaches to a surviving daemon
    // (resume) or creates a fresh one — so cold start and relaunch are the
    // same invocation; there is no spawn/reattach/restore branching here.
    // `ZMX_DIR` is pinned, and its directory pre-created (zmx's own mkdir is
    // non-recursive), so the daemon socket lands where `ZmxControlClient`
    // looks for it.
    // Consume any pending snapshot-restore path exactly once and bake it into
    // the command below. `command` is built a single time and reused for BOTH
    // the initial PaneSurface attempt and the HAN-82 ticked retry, so the path
    // is consumed once and the retry still restores. A later ensureSurface for
    // the same pane (close + reopen) finds the map already cleared, so it gets a
    // clean cold command with no stale re-restore. Do NOT move this consume into
    // the attempt/retry block or that consume-once invariant breaks.
    let restorePath = consumeRestorePath(for: pane.id)
    if restorePath != nil {
      Self.logger.info(
        "zmx.restore applied pane=\(pane.id.raw.uuidString, privacy: .public)"
      )
    }
    let session = ZmxAttachCommand.session(for: pane.id)
    let command = ZmxAttachCommand.build(
      zmxPath: try PaneDaemonBringup.zmxBinaryURL().path,
      session: session,
      userCommand: nil,
      restoreFrom: restorePath
    )
    let zmxDir = PaneDaemonBringup.canonicalSocketDirectory()
    try? FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
    var surfaceEnv = env
    surfaceEnv["ZMX_DIR"] = zmxDir.path

    // HAN-82: `ghostty_surface_new` is observed to fail transiently
    // — the user reported ~10 consecutive failures followed by a clean
    // success with no input change, suggesting an internal race that
    // resolves once libghostty has ticked. One ticked retry covers the
    // race without busy-looping; if it still fails the original
    // `GhosttyError` (now carrying a reason and a `retryable` flag) is
    // re-thrown so external callers see actionable diagnostics.
    let surface: PaneSurface
    do {
      surface = try PaneSurface(
        runtime: runtime, paneID: pane.id, session: session,
        command: command, workingDirectory: pane.workingDirectory, env: surfaceEnv
      )
    } catch GhosttyError.surfaceInitFailed(_, let retryable) where retryable {
      runtime.tick()
      surface = try PaneSurface(
        runtime: runtime, paneID: pane.id, session: session,
        command: command, workingDirectory: pane.workingDirectory, env: surfaceEnv
      )
    }
    runtime.register(pane: surface)
    // Continuous catalog write-through: record the live session so a crash
    // between launches still surfaces this pane to the next launch's reaper.
    // The socket path is derivable from the pane id + canonical ZMX_DIR; the
    // daemon PID is learned lazily via the control `.info` probe.
    if let coordinator = sessionCoordinator {
      coordinator.recordLive(
        Session(
          paneID: pane.id,
          socketPath: ZmxControlClient.socketPath(for: pane.id),
          pid: 0,
          createdAt: Date(),
          lastAttachedAt: Date(),
          command: [],
          cwd: pane.workingDirectory,
          zmxVersion: "",
          // Stamp the live login session so the next launch's reaper can
          // tell a daemon that outlived its session apart from one still
          // in the current session. See `SessionEpoch`.
          sessionEpoch: SessionEpoch.current()
        )
      )
    }
    foregroundJobPaneIDs.insert(pane.id)
    startForegroundJobPollingIfNeeded()
    surface.onClose = { [weak self] processAlive in
      self?.handleSurfaceClose(paneID: pane.id, processAlive: processAlive)
    }
    // Bridge AppKit first-responder into HierarchyManager so the tab's
    // last-focused pane tracks user clicks. Without this, click-driven
    // focus changes only update libghostty + the responder chain — the
    // catalog-level map never moves and consumers like the tab-bar
    // chip's title resolver keep reading from the wrong pane.
    surface.view.onBecomeFirstResponder = { [weak self] in
      self?.hierarchy.setLastFocusedPane(pane.id, in: tabID)
    }
    // Lets the view RESTORE firstResponder after a SwiftUI split/zoom rebuild
    // re-attaches it — only the tab's last-focused pane reclaims, so a freshly
    // split pane keeps input without siblings stealing it. Additive only.
    surface.view.shouldClaimFocus = { [weak self] in
      self?.hierarchy.lastFocusedPane(in: tabID) == pane.id
    }
    // Right-click menu items raise PaneActionRequest values directly on the
    // view; lift them onto the engine's event stream so they reach
    // PaneActionRouterFeature through the same path as libghostty-decoded
    // intents (new_split / reset / etc.). Same shape as
    // emitPaneIntent in GhosttyActionDecoder.
    surface.view.onPaneAction = { [weak self] request in
      self?.emit(.paneActionRequested(pane.id, request))
    }
    // C8a Phase 4d: forward `pane.initialCommand` to the freshly spawned shell so
    // `.shellEditor` launches ("$EDITOR\n") actually run. HierarchyManager.openPane stores
    // the command on the Pane; this is the one place it gets replayed when the surface
    // comes up.
    if let initialCommand = pane.initialCommand, !initialCommand.isEmpty {
      surface.sendInput(initialCommand + "\n")
    }
    emit(.paneCreated(pane.id, tabID))
    emit(.paneReady(pane.id))
    return surface
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
  func closeSurface(for paneID: PaneID) {
    guard let runtime = ghosttyRuntime,
      let surface = runtime.surface(for: paneID)
    else { return }
    surface.closeKillingDaemon()
    handleSurfaceClose(paneID: paneID, processAlive: true)
  }

  /// Whether a live surface is currently registered for the pane.
  /// Used by force-remove to size the "terminate N running processes"
  /// confirmation dialog (spec W-Q3).
  func hasSurface(for paneID: PaneID) -> Bool {
    guard let runtime = ghosttyRuntime else { return false }
    return runtime.surface(for: paneID) != nil
  }

  func currentWorkingDirectory(for paneID: PaneID) -> String? {
    guard let pwd = ghosttyRuntime?.surface(for: paneID)?.info.pwd,
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
  func focusSurfaceView(for paneID: PaneID) {
    focusSurfaceView(for: paneID, attempt: 0)
  }

  private func focusSurfaceView(for paneID: PaneID, attempt: Int) {
    guard attempt < 5 else { return }
    guard let runtime = ghosttyRuntime,
      let surface = runtime.surface(for: paneID)
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
      runtime.defocusAllSurfaces(except: paneID)
      if window.firstResponder !== surface.view {
        window.makeFirstResponder(surface.view)
      }
      return
    }
    let delayMs: Int = attempt == 0 ? 50 : 50 << attempt
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(delayMs))
      self?.focusSurfaceView(for: paneID, attempt: attempt + 1)
    }
  }

  private func handleSurfaceClose(paneID: PaneID, processAlive: Bool) {
    // Snapshot the surface state BEFORE unregistering so a stale registry
    // entry can't drop the lifecycle event. Unregister after emit so any
    // in-flight lookup in subscriber code still resolves the surface.
    let state = ghosttyRuntime?.surface(for: paneID)?.state ?? .ready
    disposeOutputBuffer(for: paneID)

    switch state {
    case .crashed(let reason):
      _ = recordPaneCrash(paneID: paneID, reason: reason)
    case .exited(let code):
      emit(.paneExited(paneID, code: code, signal: nil))
    default:
      // No explicit state set by markExited/markCrashed: use processAlive
      // to distinguish user-initiated close (code 0) from child exit where
      // we lack a real exit code (code -1 as a "unknown" sentinel).
      emit(.paneExited(paneID, code: processAlive ? 0 : -1, signal: nil))
    }

    ghosttyRuntime?.unregister(paneID: paneID)
    foregroundJobPaneIDs.remove(paneID)
    if let snapshot = foregroundJobSnapshots[paneID] {
      // Evict the cache entry for the closing pane's PGID so a recycled
      // group id picked up by a later pane never reads back this pane's
      // last job description.
      foregroundJobCache.removeValue(forKey: snapshot.processGroupID)
    }
    foregroundJobSnapshots.removeValue(forKey: paneID)
    foregroundJobMisses.removeValue(forKey: paneID)
    viewportSnapshots.removeValue(forKey: paneID)
    stopForegroundJobPollingIfIdle()
  }

  private func tabIDForPane(_ paneID: PaneID) -> TabID? {
    findPane(paneID)?.tabID
  }

  /// Remove and return the pending snapshot-restore path for a pane, if any.
  /// Consume-once: the entry is dropped on read, so a second call for the same
  /// pane (e.g. a close + reopen in the same session) returns `nil` and yields a
  /// cold command with no stale re-restore. Extracted as its own method so the
  /// consume-once mechanism is unit-testable without driving the libghostty
  /// surface path.
  func consumeRestorePath(for paneID: PaneID) -> String? {
    pendingRestores.removeValue(forKey: paneID)?.path
  }

  /// Process-group leader PID of the pane's current foreground job, or
  /// `nil` when the engine has not yet observed a job for this pane.
  /// The quit-time agent snapshot reads this so the persisted record
  /// carries a PID the next launch can pass to `kill(pid, 0)` for
  /// liveness. PGID is preferred over an individual process PID because
  /// it tracks the foreground group leader and survives parent/child
  /// turnover within the same agent invocation.
  func foregroundProcessGroupID(for paneID: PaneID) -> Int32? {
    foregroundJobSnapshots[paneID]?.processGroupID
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
  func appendOutput(paneID: PaneID, bytes: Data) {
    let buffer = outputBuffers[paneID] ?? makeBuffer(for: paneID)
    buffer.append(bytes)
  }

  func flushOutput(for paneID: PaneID) {
    outputBuffers[paneID]?.flush()
  }

  /// Drop the per-pane output buffer, flushing any pending bytes first. The
  /// buffer's isolated-deinit fallback exists as a safety net, but callers
  /// should invoke this explicitly when a surface closes so bytes flush
  /// while the engine is still accepting emits.
  func disposeOutputBuffer(for paneID: PaneID) {
    outputBuffers[paneID]?.flush()
    outputBuffers.removeValue(forKey: paneID)
  }

  /// Idempotent, terminal. After calling, `emit` is a no-op and all
  /// subscribers receive `finish()`. Subsequent calls are safe.
  func finishEventStream() {
    guard !finished else { return }
    finished = true
    foregroundJobPollTask?.cancel()
    foregroundJobPollTask = nil
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
    /// Enclosing Tab was auto-closed because the crash loop exceeded policy.
    case tabAutoClosed(TabID)
    /// Attempted to auto-close but `HierarchyManager.closeTab` threw; ring
    /// preserved so a later attempt can succeed. The message is the error's
    /// `localizedDescription` — callers needing the typed error should
    /// observe `HierarchyManager.catalog` for drift instead of re-throwing.
    case closeFailed(String)
  }

  @discardableResult
  func recordPaneCrash(
    paneID: PaneID,
    reason: String
  ) -> CrashOutcome {
    // Flush any buffered output so subscribers see the final bytes BEFORE the
    // crash event — otherwise the UI shows a stale prompt with the crash
    // overlay and consumers miss the last line of whatever the pane emitted.
    disposeOutputBuffer(for: paneID)
    emit(.paneCrashed(paneID, reason: reason))

    let now = clock()
    let cutoff = now.addingTimeInterval(-crashPolicy.window)
    var ring = crashRings[paneID, default: []].filter { $0 >= cutoff }
    ring.append(now)
    // Cap the ring so repeated crashes inside the window can't grow memory.
    if ring.count > crashPolicy.maxCrashesInWindow {
      ring = Array(ring.suffix(crashPolicy.maxCrashesInWindow))
    }
    crashRings[paneID] = ring

    guard ring.count >= crashPolicy.maxCrashesInWindow else {
      return .survived
    }

    guard let location = findPane(paneID) else {
      crashRings.removeValue(forKey: paneID)
      return .survived
    }

    // Snapshot sibling panes BEFORE closeTab removes them. Each gets its
    // own paneExited event so per-pane subscribers can release state.
    let siblingPaneIDs = siblingPaneIDs(in: location, excluding: paneID)

    do {
      try hierarchy.closeTab(
        location.tabID,
        in: location.worktreeID,
        in: location.projectID
      )
    } catch {
      // Preserve the ring so a retry can still close the tab.
      return .closeFailed(error.localizedDescription)
    }

    crashRings.removeValue(forKey: paneID)
    let cause: TabAutoCloseCause = .crashLoop(count: ring.count, window: crashPolicy.window)
    for siblingID in siblingPaneIDs {
      disposeOutputBuffer(for: siblingID)
      // Forced close, not clean exit — distinct variant so persistence and
      // C3 hook consumers don't misreport as code-0 exit.
      emit(.paneClosedByTab(siblingID, cause: cause))
    }
    emit(.tabAutoClosed(location.tabID, cause: cause))
    return .tabAutoClosed(location.tabID)
  }

  /// Retry a crashed pane. Returns false when the pane no longer exists
  /// (e.g. its Tab was already auto-closed). M5 replaces the stub body with
  /// real surface recreation via GhosttyRuntime.createSurface.
  @discardableResult
  func retryPane(_ paneID: PaneID) -> Bool {
    guard findPane(paneID) != nil else {
      return false
    }
    crashRings.removeValue(forKey: paneID)
    emit(.paneReady(paneID))
    return true
  }

  // MARK: - Private

  private struct PaneLocation {
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let tabID: TabID
  }

  private func findPane(_ paneID: PaneID) -> PaneLocation? {
    for project in hierarchy.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return PaneLocation(
            projectID: project.id,
            worktreeID: worktree.id,
            tabID: tab.id
          )
        }
      }
    }
    return nil
  }

  private func siblingPaneIDs(
    in location: PaneLocation,
    excluding excluded: PaneID
  ) -> [PaneID] {
    guard
      let project = hierarchy.catalog.projects.first(where: { $0.id == location.projectID }),
      let worktree = project.worktrees.first(where: { $0.id == location.worktreeID }),
      let tab = worktree.tabs.first(where: { $0.id == location.tabID })
    else {
      return []
    }
    return tab.panes.map(\.id).filter { $0 != excluded }
  }

  private func makeBuffer(for paneID: PaneID) -> PendingOutputBuffer {
    // The engine must outlive its output buffers. disposeOutputBuffer drops
    // the buffer while the engine is still broadcasting, so the weak capture
    // only matters as a safety net if the buffer is dropped via deinit after
    // finishEventStream — in that case emit is a no-op, bytes silently fall
    // on the floor (documented trade-off).
    let buffer = PendingOutputBuffer(paneID: paneID) { [weak self] id, data in
      self?.emit(.paneOutput(id, data))
    }
    outputBuffers[paneID] = buffer
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
    guard foregroundJobPaneIDs.isEmpty else { return }
    foregroundJobPollTask?.cancel()
    foregroundJobPollTask = nil
  }

  private func pollForegroundJobs() {
    guard let ghosttyRuntime, !foregroundJobPaneIDs.isEmpty else { return }

    var groupByPane: [PaneID: Int32] = [:]
    for paneID in foregroundJobPaneIDs {
      guard let surface = ghosttyRuntime.surface(for: paneID),
        let groupID = foregroundJobReader.resolveProcessGroupID(
          preferred: surface.foregroundProcessGroupID(),
          childPID: surface.childProcessID()
        )
      else {
        continue
      }
      groupByPane[paneID] = groupID
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

    for paneID in foregroundJobPaneIDs {
      let next: ForegroundJob
      if let groupID = groupByPane[paneID], let job = jobsByGroup[groupID] {
        next = job
      } else {
        next = ForegroundJob(processGroupID: groupByPane[paneID] ?? 0, processes: [])
      }

      if next.isEmpty, foregroundJobSnapshots[paneID] == nil {
        continue
      }
      if next.isEmpty {
        let misses = min((foregroundJobMisses[paneID] ?? 0) + 1, 3)
        foregroundJobMisses[paneID] = misses
        guard misses >= 3 else { continue }
      } else {
        foregroundJobMisses[paneID] = 0
      }
      if foregroundJobSnapshots[paneID] != next {
        foregroundJobSnapshots[paneID] = next
        emit(.foregroundJobChanged(paneID, next))
      }
      if let surface = ghosttyRuntime.surface(for: paneID) {
        emitViewportIfNeeded(paneID: paneID, surface: surface, foregroundJob: next)
      }
    }
  }

  private func foregroundJobPollInterval() -> Duration {
    var sawRunningCommand = false
    for paneID in foregroundJobPaneIDs {
      if hierarchy.catalog.pane(paneID)?.agentKind != nil {
        return .milliseconds(300)
      }
      if let job = foregroundJobSnapshots[paneID] {
        if AgentKindPatterns.classify(foregroundJob: job) != nil {
          return .milliseconds(300)
        }
        if ForegroundJobClassifier.indicatesRunningCommand(job) {
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
    paneID: PaneID,
    surface: PaneSurface,
    foregroundJob: ForegroundJob
  ) {
    let hasAgentSignal =
      hierarchy.catalog.pane(paneID)?.agentKind != nil
      || AgentKindPatterns.classify(foregroundJob: foregroundJob) != nil
    // Classify against the active interaction region, not the whole viewport:
    // scrollback that happens to still be visible must not pin the agent on a
    // stale prompt/spinner.
    guard hasAgentSignal, let text = surface.readText(.active) else { return }
    guard viewportSnapshots[paneID] != text else { return }
    viewportSnapshots[paneID] = text
    emit(.paneViewportChanged(paneID, text: text))
  }
}

extension TerminalEvent {
  /// Lifecycle events must not drop under consumer backpressure — they drive
  /// persistence and TCA state machines. Output events are safe to drop
  /// because scrollback retains history.
  fileprivate var isLifecycle: Bool {
    switch self {
    case .paneOutput, .paneViewportChanged, .paneIdle, .paneInfoChanged, .foregroundJobChanged:
      return false
    case .paneCreated, .paneReady, .paneExited, .paneCrashed,
      .paneClosedByTab, .tabActivated, .tabAutoClosed,
      .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      return true
    }
  }
}
