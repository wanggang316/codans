import Foundation
import TouchCodeCore

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

  private let registry = SubscriberRegistry()
  private var outputBuffers: [PaneID: PendingOutputBuffer] = [:]
  private var crashRings: [PaneID: [Date]] = [:]
  private let clock: @Sendable () -> Date
  private var finished = false

  /// Inject a `GhosttyRuntime` for real pane surfaces, or pass `nil` for
  /// headless tests. When nil, `ensureSurface` throws.
  init(
    store: CatalogStore,
    hierarchy: HierarchyManager,
    ghosttyRuntime: GhosttyRuntime? = nil,
    clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.hierarchy = hierarchy
    self.ghosttyRuntime = ghosttyRuntime
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

  /// Create a libghostty surface for the given Pane. Idempotent: if a
  /// surface is already registered for the pane, returns the existing one.
  /// Wires the surface's `onClose` to emit the lifecycle event + dispose
  /// buffer. Throws `paneHasNoTab` if the Pane isn't yet wired into a
  /// Tab — the engine uses the Tab ID in the `.paneCreated` event, so
  /// callers must add the Pane to a Tab via `HierarchyManager.openPane`
  /// (or `splitPane`) before calling this.
  @discardableResult
  func ensureSurface(
    for pane: Pane,
    in worktree: Worktree,
    env: [String: String] = [:]
  ) throws -> PaneSurface {
    guard let runtime = ghosttyRuntime else { throw SurfaceError.runtimeUnavailable }
    if let existing = runtime.surface(for: pane.id) {
      return existing
    }
    guard let tabID = tabIDForPane(pane.id) else {
      throw SurfaceError.paneHasNoTab
    }
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
        runtime: runtime,
        paneID: pane.id,
        workingDirectory: pane.workingDirectory,
        env: env
      )
    } catch GhosttyError.surfaceInitFailed(_, let retryable) where retryable {
      runtime.tick()
      surface = try PaneSurface(
        runtime: runtime,
        paneID: pane.id,
        workingDirectory: pane.workingDirectory,
        env: env
      )
    }
    runtime.register(pane: surface)
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
  func closeSurface(for paneID: PaneID) {
    guard let runtime = ghosttyRuntime,
      let surface = runtime.surface(for: paneID)
    else { return }
    surface.close()
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
  }

  private func tabIDForPane(_ paneID: PaneID) -> TabID? {
    findPane(paneID)?.tabID
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
}

extension TerminalEvent {
  /// Lifecycle events must not drop under consumer backpressure — they drive
  /// persistence and TCA state machines. Output events are safe to drop
  /// because scrollback retains history.
  fileprivate var isLifecycle: Bool {
    switch self {
    case .paneOutput, .paneIdle, .paneInfoChanged:
      return false
    case .paneCreated, .paneReady, .paneExited, .paneCrashed,
      .paneClosedByTab, .tabActivated, .tabAutoClosed,
      .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      return true
    }
  }
}
