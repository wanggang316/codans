import ComposableArchitecture
import Foundation

/// Reducer backing the Settings → Terminal pane. Loads the user's Ghostty config
/// snapshot on appear, pushes light / dark theme picks through
/// `GhosttyTerminalSettingsClient.apply`, and surfaces load / apply errors inline.
///
/// Apply calls are coalesced via a cancellable: a fast re-selection cancels the
/// in-flight write before issuing the new one, so the filesystem sees at most one
/// write per resting user intent.
@Reducer
struct SettingsTerminalFeature {
  @ObservableState
  struct State: Equatable {
    var snapshot: GhosttyTerminalSettings?
    var isLoading = false
    var isApplying = false
    var errorMessage: String?
    /// Carried through from `GhosttyTerminalSettings.warningMessage` so the pane can
    /// surface non-fatal config-parse warnings (e.g., a legacy single-name `theme`
    /// directive that will be rewritten on next save).
    var warningMessage: String?
  }

  enum Action: Equatable {
    case onAppear
    case loadResult(Result<GhosttyTerminalSettings, ApplyError>)
    case lightThemeSelected(String?)
    case darkThemeSelected(String?)
    case applyResult(Result<GhosttyTerminalSettings, ApplyError>)
  }

  /// `Equatable`-wrapped error carrier. The underlying errors thrown by
  /// `GhosttyConfigFile` already provide `localizedDescription`; we collapse to a
  /// string so the reducer state stays `Equatable` for `TestStore` assertions.
  struct ApplyError: Equatable, Error {
    let message: String
    init(_ error: Error) {
      self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
    init(message: String) {
      self.message = message
    }
  }

  nonisolated enum CancelID: Sendable { case apply }

  @Dependency(GhosttyTerminalSettingsClient.self) var client

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        guard state.snapshot == nil, !state.isLoading else { return .none }
        state.isLoading = true
        state.errorMessage = nil
        return .run { send in
          do {
            let snapshot = try await client.load()
            await send(.loadResult(.success(snapshot)))
          } catch {
            await send(.loadResult(.failure(ApplyError(error))))
          }
        }

      case .loadResult(.success(let snapshot)):
        state.isLoading = false
        state.snapshot = snapshot
        state.warningMessage = snapshot.warningMessage
        return .none

      case .loadResult(.failure(let error)):
        state.isLoading = false
        state.errorMessage = error.message
        return .none

      case .lightThemeSelected(let name):
        return applyDraft(state: &state, lightTheme: name, darkTheme: state.snapshot?.darkTheme)

      case .darkThemeSelected(let name):
        return applyDraft(state: &state, lightTheme: state.snapshot?.lightTheme, darkTheme: name)

      case .applyResult(.success(let snapshot)):
        state.isApplying = false
        state.snapshot = snapshot
        state.warningMessage = snapshot.warningMessage
        state.errorMessage = nil
        return .none

      case .applyResult(.failure(let error)):
        state.isApplying = false
        state.errorMessage = error.message
        return .none
      }
    }
  }

  /// Shared tail for `lightThemeSelected` / `darkThemeSelected`. Cancels any in-flight
  /// apply before queueing a fresh one so the user's latest pick is the one that lands.
  private func applyDraft(
    state: inout State,
    lightTheme: String?,
    darkTheme: String?
  ) -> Effect<Action> {
    state.isApplying = true
    state.errorMessage = nil
    let draft = GhosttyTerminalSettingsDraft(lightTheme: lightTheme, darkTheme: darkTheme)
    return .run { send in
      do {
        let snapshot = try await client.apply(draft)
        await send(.applyResult(.success(snapshot)))
      } catch {
        await send(.applyResult(.failure(ApplyError(error))))
      }
    }
    .cancellable(id: CancelID.apply, cancelInFlight: true)
  }
}
