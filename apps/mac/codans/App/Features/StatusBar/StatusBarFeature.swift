import ComposableArchitecture
import Foundation
import CodansCore

/// Reducer backing the Worktree Status Bar's center slot. Owns a single
/// transient `toast` value and its auto-clear lifecycle.
///
/// PR and motivational forms are view-level projections of other state
/// (`GitHubFeature.snapshots`, time of day) — not managed here. This reducer
/// only decides which toast (if any) is active and when it expires.
///
/// Auto-clear windows:
///   * `.success`    — 3 s
///   * `.warning`    — 8 s
///   * `.inProgress` — never auto-clears; emitter must push a terminal state.
///
/// Race-safe against rapid pushes: every push bumps `sequence` and the
/// scheduled `.cleared(sequence:)` fires a no-op if its captured sequence no
/// longer matches current state. That lets `.cancellable(cancelInFlight:)`
/// co-exist with a suspended `clock.sleep` that may still dispatch past its
/// cancellation point.
@Reducer
struct StatusBarFeature {
  @ObservableState
  struct State: Equatable {
    var toast: StatusToast?
    /// Monotonic token bumped on every `.push`. Auto-clear timers validate
    /// their captured value against this before mutating state.
    var sequence: UInt64 = 0
  }

  enum Action: Equatable {
    case push(StatusToast)
    case cleared(sequence: UInt64)
    case dismissed
  }

  nonisolated enum CancelID: Sendable { case autoClearTimer }

  static let successDuration: Duration = .seconds(3)
  static let warningDuration: Duration = .seconds(8)

  @Dependency(\.continuousClock) var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .push(let toast):
        state.toast = toast
        state.sequence &+= 1
        let capturedSequence = state.sequence
        let delay: Duration? = {
          switch toast {
          case .inProgress: return nil
          case .success: return Self.successDuration
          case .warning: return Self.warningDuration
          }
        }()
        guard let delay else {
          return .cancel(id: CancelID.autoClearTimer)
        }
        return .run { [clock] send in
          try? await clock.sleep(for: delay)
          await send(.cleared(sequence: capturedSequence))
        }
        .cancellable(id: CancelID.autoClearTimer, cancelInFlight: true)

      case .cleared(let seq):
        if seq == state.sequence {
          state.toast = nil
        }
        return .none

      case .dismissed:
        state.toast = nil
        return .cancel(id: CancelID.autoClearTimer)
      }
    }
  }
}
