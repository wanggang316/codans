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
    case cursorStyleSelected(GhosttyCursorStyle?)
    case fontFamilySelected(String?)
    case fontSizeSelected(Double?)
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
        return applyDraft(state: &state, draft: draft(from: state.snapshot, lightTheme: name))

      case .darkThemeSelected(let name):
        return applyDraft(state: &state, draft: draft(from: state.snapshot, darkTheme: name))

      case .cursorStyleSelected(let style):
        return applyDraft(state: &state, draft: draft(from: state.snapshot, cursorStyle: style))

      case .fontFamilySelected(let name):
        return applyDraft(state: &state, draft: draft(from: state.snapshot, fontFamily: name))

      case .fontSizeSelected(let size):
        return applyDraft(state: &state, draft: draft(from: state.snapshot, fontSize: size))

      case .applyResult(.success(let applied)):
        state.isApplying = false
        // An apply only changes directive values; the theme / font catalogs are
        // unchanged. Carry the already-loaded catalog forward so the theme rows
        // don't visibly reload, and so a fast pick needn't re-enumerate disk +
        // system fonts. Fall back to the applied snapshot if we somehow had none.
        state.snapshot = state.snapshot.map { $0.merging(directivesFrom: applied) } ?? applied
        state.warningMessage = applied.warningMessage
        state.errorMessage = nil
        return .none

      case .applyResult(.failure(let error)):
        state.isApplying = false
        state.errorMessage = error.message
        return .none
      }
    }
  }

  /// Build a draft mirroring the current snapshot, overriding exactly the
  /// fields the caller passes. Each parameter is a *double* optional: omitting
  /// it (`.none`) inherits the snapshot's value; passing `field: x` (where `x`
  /// is itself optional) sets it — including `field: nil`, which clears the
  /// directive. This lets a single picker change one directive while carrying
  /// the rest of the managed block forward unchanged.
  private func draft(
    from snapshot: GhosttyTerminalSettings?,
    lightTheme: String?? = nil,
    darkTheme: String?? = nil,
    cursorStyle: GhosttyCursorStyle?? = nil,
    fontFamily: String?? = nil,
    fontSize: Double?? = nil
  ) -> GhosttyTerminalSettingsDraft {
    GhosttyTerminalSettingsDraft(
      lightTheme: lightTheme ?? snapshot?.lightTheme,
      darkTheme: darkTheme ?? snapshot?.darkTheme,
      cursorStyle: cursorStyle ?? snapshot?.cursorStyle,
      fontFamily: fontFamily ?? snapshot?.fontFamily,
      fontSize: fontSize ?? snapshot?.fontSize
    )
  }

  /// Cancels any in-flight apply before queueing a fresh one so the user's
  /// latest pick is the one that lands.
  private func applyDraft(
    state: inout State,
    draft: GhosttyTerminalSettingsDraft
  ) -> Effect<Action> {
    state.isApplying = true
    state.errorMessage = nil
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
