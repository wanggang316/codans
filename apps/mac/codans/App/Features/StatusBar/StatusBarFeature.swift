import ComposableArchitecture
import Foundation
import CodansCore

/// Reducer backing the Worktree Status Bar's center slot. Owns the two
/// reducer-managed inputs of the slot:
///
///   * `activities` — user-initiated work still running. Keyed by
///     `StatusActivityID`; each lives until its emitter sends `.end`.
///   * `toast` — the latest outcome notice, auto-cleared after
///     3 s (`.success`) / 8 s (`.warning`).
///
/// PR and motivational forms are view-level projections of other state
/// (`GitHubFeature.snapshots`, time of day) — not managed here.
///
/// Toast auto-clear is race-safe against rapid pushes: every push bumps
/// `sequence` and the scheduled `.cleared(sequence:)` is a no-op if its
/// captured sequence no longer matches current state, so a suspended
/// `clock.sleep` that resumes past its cancellation cannot clear a newer toast.
@Reducer
struct StatusBarFeature {
  @ObservableState
  struct State: Equatable {
    var toast: StatusToast?
    /// Monotonic token bumped on every toast push. Auto-clear timers validate
    /// their captured value against this before mutating state.
    var sequence: UInt64 = 0
    /// Running work in begin order; the last element is the one the slot shows.
    var activities: IdentifiedArrayOf<StatusActivity> = []

    /// Activity the status slot features: the most recently begun.
    var primaryActivity: StatusActivity? { activities.last }
  }

  enum Action: Equatable {
    /// Show an outcome notice, replacing any current one.
    case push(StatusToast)
    case cleared(sequence: UInt64)
    case dismissed
    /// Start (or restart) an activity. An existing id is replaced and moves
    /// to the front, so a retried operation never shows twice.
    case begin(StatusActivity)
    /// Refresh a running activity's detail and progress. Ignored once ended.
    case update(id: StatusActivityID, detail: String?, progress: StatusActivity.Progress)
    /// Finish an activity and optionally report how it went. An unknown id
    /// still pushes the outcome, so late or duplicate ends stay harmless.
    case end(id: StatusActivityID, outcome: StatusToast?)
    /// Stop pressed on a cancellable activity in the popover.
    case cancelTapped(StatusActivityID)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      /// The emitter must stop the work. The activity is already gone, so the
      /// emitter's own later `.end` only matters for its outcome toast.
      case cancelRequested(StatusActivityID)
    }
  }

  nonisolated enum CancelID: Sendable { case autoClearTimer }

  static let successDuration: Duration = .seconds(3)
  static let warningDuration: Duration = .seconds(8)

  @Dependency(\.continuousClock) var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .push(let toast):
        return push(toast, into: &state)

      case .cleared(let seq):
        if seq == state.sequence {
          state.toast = nil
        }
        return .none

      case .dismissed:
        state.toast = nil
        return .cancel(id: CancelID.autoClearTimer)

      case .begin(let activity):
        state.activities.remove(id: activity.id)
        state.activities.append(activity)
        return .none

      case .update(let id, let detail, let progress):
        state.activities[id: id]?.detail = detail
        state.activities[id: id]?.progress = progress
        return .none

      case .end(let id, let outcome):
        state.activities.remove(id: id)
        guard let outcome else { return .none }
        return push(outcome, into: &state)

      case .cancelTapped(let id):
        guard state.activities[id: id]?.isCancellable == true else { return .none }
        state.activities.remove(id: id)
        return .send(.delegate(.cancelRequested(id)))

      case .delegate:
        return .none
      }
    }
  }

  private func push(_ toast: StatusToast, into state: inout State) -> Effect<Action> {
    state.toast = toast
    state.sequence &+= 1
    let capturedSequence = state.sequence
    let delay: Duration =
      switch toast {
      case .success: Self.successDuration
      case .warning: Self.warningDuration
      }
    return .run { [clock] send in
      try? await clock.sleep(for: delay)
      await send(.cleared(sequence: capturedSequence))
    }
    .cancellable(id: CancelID.autoClearTimer, cancelInFlight: true)
  }
}
