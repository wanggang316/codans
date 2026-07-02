import CodansCore
import ComposableArchitecture
import Foundation
import OSLog

private let paneHostLogger = Logger(subsystem: "com.gumpw.codans.shell", category: "pane-host")

/// Lifecycle reducer for a single pane's `PaneSurface`. Owns the
/// first-resolve, retry, and failure surfacing that used to live in a
/// SwiftUI view body. `@Dependency(TerminalClient.self)` sits here
/// (reducer-scoped, where `Store.withDependencies` in `bringUp()` actually
/// binds) rather than in the view, which otherwise would fall through to
/// `TerminalClient.liveValue`'s fatal-stub.
///
/// `terminalClient.ensureSurface` is `async throws` (it spawns the
/// `zmx serve` daemon and handshakes the control socket), so resolve
/// runs inside an `Effect.run` and dispatches `.resolveCompleted` /
/// `.resolveFailed` back into the reducer on completion.
@Reducer
struct PaneHostFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let paneID: PaneID
    let tabID: TabID
    let worktreeID: WorktreeID
    let projectID: ProjectID
    var phase: Phase = .loading
    /// Non-nil exactly when `phase == .ready`. Identity-equatable via
    /// `SurfaceBox`; the live surface is owned by `TerminalEngine`'s
    /// registry.
    var surface: SurfaceBox?

    var id: PaneID { paneID }

    enum Phase: Equatable {
      case loading
      case ready
      case failed(String)
    }
  }

  enum Action: Equatable {
    /// Fired from `LeafView`'s `.task` (routed through the parent store
    /// behind a membership check — see `LazyPaneHost`'s doc). Idempotent:
    /// registry short-circuit keeps re-renders free.
    case task
    case retryButtonTapped
    /// Internal: the async `ensureSurface` call returned successfully and
    /// the registry now holds a surface for this pane.
    case resolveCompleted(SurfaceBox)
    /// Internal: bring-up failed (zmx spawn, control-socket connect, or
    /// `ghostty_surface_new`). `reason` is the error's debug description.
    case resolveFailed(String)
  }

  @Dependency(TerminalClient.self) private var terminalClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .retryButtonTapped:
        state.phase = .loading
        state.surface = nil
        return resolveSurface(state: state)
      case .task:
        return resolveSurface(state: state)
      case .resolveCompleted(let box):
        state.phase = .ready
        state.surface = box
        return .none
      case .resolveFailed(let message):
        let paneIDDescription = state.paneID.description
        paneHostLogger.error(
          "ensureSurface failed for \(paneIDDescription, privacy: .public): \(message, privacy: .public)"
        )
        state.phase = .failed(message)
        state.surface = nil
        return .none
      }
    }
  }

  private func resolveSurface(state: State) -> Effect<Action> {
    // Registry short-circuit on the main thread — when the surface is
    // already wired (e.g. the prior tab-switch eagerly seeded it via
    // `selectionChanges`), avoid scheduling an async effect just to
    // re-discover it.
    if let existing = terminalClient.surface(state.paneID) {
      return .send(.resolveCompleted(SurfaceBox(surface: existing)))
    }
    let paneID = state.paneID
    let tabID = state.tabID
    let worktreeID = state.worktreeID
    let projectID = state.projectID
    return .run { [client = terminalClient] send in
      do {
        try await client.ensureSurface(paneID, tabID, worktreeID, projectID)
      } catch {
        await send(.resolveFailed(String(describing: error)))
        return
      }
      if let surface = await client.surface(paneID) {
        await send(.resolveCompleted(SurfaceBox(surface: surface)))
      } else {
        await send(.resolveFailed("Surface not registered after creation."))
      }
    }
  }
}

/// Identity-compared wrapper so `PaneSurface` (reference type, not
/// `Equatable`) can live in reducer state without leaking `===` semantics
/// through a global extension.
struct SurfaceBox: Equatable {
  let surface: PaneSurface
  static func == (lhs: SurfaceBox, rhs: SurfaceBox) -> Bool {
    lhs.surface === rhs.surface
  }
}
