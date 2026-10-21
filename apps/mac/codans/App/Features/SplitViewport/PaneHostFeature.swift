import CodansCore
import ComposableArchitecture
import Foundation
import OSLog

private let paneHostLogger = Logger(subsystem: "com.gumpw.codans.shell", category: "pane-host")

/// Lifecycle reducer for one shown Content's `PaneSurface`. Owns the
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
    /// The session shown in the slot; the host's identity, so switching
    /// the Pane's selected Tab swaps the host.
    let contentID: ContentID
    /// Where the Tab sat when the host was seeded. Informational — the
    /// engine resolves the live address from the catalog.
    let paneID: PaneID
    let tabID: TabID
    let worktreeID: WorktreeID
    let projectID: ProjectID
    var phase: Phase = .loading
    /// Non-nil exactly when `phase == .ready`. Identity-equatable via
    /// `SurfaceBox`; the live surface is owned by `TerminalEngine`'s
    /// registry.
    var surface: SurfaceBox?
    /// Size in points of the slot that shows this pane, from the last
    /// `.task`. A retry reuses it.
    var slotSize: CGSize?

    var id: ContentID { contentID }

    enum Phase: Equatable {
      case loading
      case ready
      case failed(Failure)
    }
  }

  /// What the failure placeholder shows: a sentence the user can act on,
  /// plus the raw error kept for bug reports.
  nonisolated struct Failure: Equatable {
    let reason: String
    /// `String(describing:)` of the underlying error; nil when it would only
    /// repeat `reason`.
    let detail: String?

    init(reason: String, detail: String? = nil) {
      self.reason = reason
      self.detail = detail
    }

    init(error: any Error) {
      let detail = String(describing: error)
      let reason = (error as? LocalizedError)?.errorDescription ?? detail
      self.init(reason: reason, detail: reason == detail ? nil : detail)
    }
  }

  enum Action: Equatable {
    /// Fired from `LeafView`'s `.task` (routed through the parent store
    /// behind a membership check — see `LazyPaneHost`'s doc). Idempotent:
    /// registry short-circuit keeps re-renders free. `slotSize` is the
    /// laid-out size of the slot: a new surface starts at it, so a
    /// live session behind a re-attach is not resized through a
    /// placeholder width first.
    case task(slotSize: CGSize)
    case retryButtonTapped
    /// Internal: the async `ensureSurface` call returned successfully and
    /// the registry now holds a surface for this Content.
    case resolveCompleted(SurfaceBox)
    /// Internal: bring-up failed (missing zmx binary, unresolvable Content, or
    /// `ghostty_surface_new`).
    case resolveFailed(Failure)
  }

  @Dependency(TerminalClient.self) private var terminalClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .retryButtonTapped:
        state.phase = .loading
        state.surface = nil
        return resolveSurface(state: state)
      case .task(let slotSize):
        if slotSize.width > 0, slotSize.height > 0 {
          state.slotSize = slotSize
        }
        return resolveSurface(state: state)
      case .resolveCompleted(let box):
        state.phase = .ready
        state.surface = box
        return .none
      case .resolveFailed(let failure):
        let contentIDDescription = state.contentID.description
        let message = failure.detail ?? failure.reason
        paneHostLogger.error(
          "ensureSurface failed for \(contentIDDescription, privacy: .public): \(message, privacy: .public)"
        )
        state.phase = .failed(failure)
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
    if let existing = terminalClient.surface(state.contentID) {
      return .send(.resolveCompleted(SurfaceBox(surface: existing)))
    }
    let contentID = state.contentID
    let initialSize = state.slotSize
    return .run { [client = terminalClient] send in
      do {
        try await client.ensureSurface(contentID, initialSize)
      } catch {
        await send(.resolveFailed(Failure(error: error)))
        return
      }
      if let surface = await client.surface(contentID) {
        await send(.resolveCompleted(SurfaceBox(surface: surface)))
      } else {
        await send(.resolveFailed(Failure(reason: "Surface not registered after creation.")))
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
