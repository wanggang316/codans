import ComposableArchitecture
import Foundation
import CodansCore

/// TCA dependency-injection bridge over `TerminalEngine`. Features depend on
/// this struct's closures, not on the engine directly; the `liveValue` binds
/// each closure to a concrete `TerminalEngine` instance at app startup via
/// `.withDependencies`.
nonisolated struct TerminalClient: Sendable {
  var sendInput: @MainActor @Sendable (_ paneID: PaneID, _ text: String) -> Void
  /// Interrupt the pane's foreground process (Ctrl-C → SIGINT). Goes through
  /// the key-event path rather than `sendInput`, whose text path filters
  /// control bytes. No-op when the pane has no live surface.
  var interrupt: @MainActor @Sendable (_ paneID: PaneID) -> Void
  var setFocus: @MainActor @Sendable (_ paneID: PaneID, _ focused: Bool) -> Void
  var retryPane: @MainActor @Sendable (_ paneID: PaneID) -> Bool

  /// Create or return the existing `PaneSurface` for the pane. Throws
  /// `TerminalClient.Error.worktreeNotFound` if the worktree address doesn't
  /// resolve inside the current catalog. The client takes the full address
  /// so the engine's `ensureSurface(for:in:)` can hand the `Worktree`
  /// struct to ghostty as the surface config's working directory source.
  ///
  /// `async throws` because bring-up spawns the `zmx serve` daemon and
  /// completes a control-socket handshake before libghostty wires the
  /// External PTY backend onto the new surface.
  var ensureSurface:
    @MainActor @Sendable (
      _ paneID: PaneID, _ inTab: TabID, _ inWorktree: WorktreeID,
      _ inProject: ProjectID
    ) async throws -> Void
  var closeSurface: @MainActor @Sendable (_ paneID: PaneID) -> Void

  /// Look up an existing `PaneSurface` registered with the engine. Returns
  /// `nil` when no surface has been created for the pane yet; callers
  /// (notably `LazyPaneHost`) should call `ensureSurface` first on a
  /// cache miss.
  var surface: @MainActor @Sendable (_ paneID: PaneID) -> PaneSurface?

  /// Event stream from the engine. Multi-consumer: each call returns a fresh
  /// subscriber registration. Lifecycle events always delivered; output
  /// events drop under per-subscriber backpressure.
  var events: @MainActor @Sendable () -> AsyncStream<TerminalEvent>

  enum Error: Swift.Error, Equatable, Sendable {
    case worktreeNotFound(WorktreeID)
    case paneNotFound(PaneID)
  }
}

// MARK: - Live bridge

extension TerminalClient {
  @MainActor
  static func live(engine: TerminalEngine) -> TerminalClient {
    TerminalClient(
      sendInput: { paneID, text in
        engine.ghosttyRuntime?.surface(for: paneID)?.sendInput(text)
      },
      interrupt: { paneID in
        engine.ghosttyRuntime?.surface(for: paneID)?.sendInterrupt()
      },
      setFocus: { paneID, focused in
        engine.ghosttyRuntime?.surface(for: paneID)?.setFocus(focused)
      },
      retryPane: { paneID in engine.retryPane(paneID) },
      ensureSurface: { paneID, tabID, worktreeID, projectID in
        let catalog = engine.hierarchy.catalog
        guard
          let project = catalog.projects.first(where: { $0.id == projectID }),
          let worktree = project.worktrees.first(where: { $0.id == worktreeID }),
          let tab = worktree.tabs.first(where: { $0.id == tabID }),
          let pane = tab.panes.first(where: { $0.id == paneID })
        else {
          throw TerminalClient.Error.worktreeNotFound(worktreeID)
        }
        _ = try await engine.ensureSurface(for: pane, in: worktree)
      },
      closeSurface: { paneID in engine.closeSurface(for: paneID) },
      surface: { paneID in engine.ghosttyRuntime?.surface(for: paneID) },
      events: { engine.events() }
    )
  }
}

// MARK: - DependencyKey

extension TerminalClient: DependencyKey {
  static let liveValue: TerminalClient = TerminalClient(
    sendInput: { _, _ in
      fatalError("TerminalClient.liveValue not configured; wire via .withDependencies at app startup")
    },
    interrupt: { _ in fatalError("TerminalClient.liveValue not configured") },
    setFocus: { _, _ in fatalError("TerminalClient.liveValue not configured") },
    retryPane: { _ in fatalError("TerminalClient.liveValue not configured") },
    ensureSurface: { _, _, _, _ in fatalError("TerminalClient.liveValue not configured") },
    closeSurface: { _ in fatalError("TerminalClient.liveValue not configured") },
    surface: { _ in nil },
    events: { AsyncStream { $0.finish() } }
  )

  static let testValue: TerminalClient = TerminalClient(
    sendInput: unimplemented("TerminalClient.sendInput"),
    interrupt: unimplemented("TerminalClient.interrupt"),
    setFocus: unimplemented("TerminalClient.setFocus"),
    retryPane: unimplemented("TerminalClient.retryPane", placeholder: false),
    ensureSurface: unimplemented("TerminalClient.ensureSurface"),
    closeSurface: unimplemented("TerminalClient.closeSurface"),
    // Quiet `{ _ in nil }` mirrors the liveValue fallback above: pane-host
    // / view-side lookups for a not-yet-attached surface are an expected
    // outcome, not a test contract worth asserting. Without this default,
    // detached SwiftUI tasks in the test host record an issue against
    // `unimplemented(...)` after their owning test scope has finished.
    surface: { _ in nil },
    events: unimplemented(
      "TerminalClient.events",
      placeholder: AsyncStream { $0.finish() }
    )
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
