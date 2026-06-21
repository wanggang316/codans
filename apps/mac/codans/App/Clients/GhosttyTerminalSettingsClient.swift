import ComposableArchitecture
import Foundation

/// TCA dependency-injection bridge over `GhosttyConfigFile`. Features depend
/// on these two async closures, not on the file type directly; `liveValue`
/// is intentionally unwired so the real factory is applied at startup via
/// `.withDependencies { $0.ghosttyTerminalSettingsClient = .appLive() }`.
///
/// Mirrors the `EditorClient` / `HierarchyClient` conventions: the struct
/// is `nonisolated Sendable` (closures hop to MainActor inside), live + test
/// values live on the `DependencyKey` conformance, and the registry hook is
/// a computed property on `DependencyValues`.
nonisolated struct GhosttyTerminalSettingsClient: Sendable {
  var load: @Sendable () async throws -> GhosttyTerminalSettings
  var apply: @Sendable (GhosttyTerminalSettingsDraft) async throws -> GhosttyTerminalSettings
}

// MARK: - DependencyKey

extension GhosttyTerminalSettingsClient: DependencyKey {
  /// Unwired live value — throws `.configDirectoryUnavailable("unwired")`
  /// until `AppState.bringUp()` (M4) replaces it with `.appLive()`. We use a
  /// throw rather than a `fatalError` here because the Settings pane renders
  /// errors inline, and an unwired dependency should surface as "Ghostty
  /// config directory is unavailable: unwired" rather than crash the app.
  static let liveValue = Self(
    load: { throw GhosttyConfigFileError.configDirectoryUnavailable("unwired") },
    apply: { _ in throw GhosttyConfigFileError.configDirectoryUnavailable("unwired") }
  )

  /// Deterministic fixture for reducer tests. Mirrors the live shape:
  /// `load` returns an empty catalog and no selection; `apply` echoes the
  /// draft back through the snapshot so the reducer can assert round-trips.
  static let testValue = Self(
    load: {
      GhosttyTerminalSettings(
        configPath: "/tmp/codans-tests/ghostty/config",
        lightTheme: nil,
        darkTheme: nil,
        cursorStyle: nil,
        fontFamily: nil,
        fontSize: nil,
        availableLightThemes: [],
        availableDarkThemes: [],
        availableFontFamilies: [],
        themePreviews: [:],
        warningMessage: nil
      )
    },
    apply: { draft in
      GhosttyTerminalSettings(
        configPath: "/tmp/codans-tests/ghostty/config",
        lightTheme: draft.lightTheme,
        darkTheme: draft.darkTheme,
        cursorStyle: draft.cursorStyle,
        fontFamily: draft.fontFamily,
        fontSize: draft.fontSize,
        availableLightThemes: [],
        availableDarkThemes: [],
        availableFontFamilies: [],
        themePreviews: [:],
        warningMessage: nil
      )
    }
  )
}

extension DependencyValues {
  var ghosttyTerminalSettingsClient: GhosttyTerminalSettingsClient {
    get { self[GhosttyTerminalSettingsClient.self] }
    set { self[GhosttyTerminalSettingsClient.self] = newValue }
  }
}

// MARK: - App-side live bridge

/// Real factory applied at app startup. Lives in an @MainActor extension so
/// the `GhosttyConfigFile()` default init (which touches `FileManager` +
/// `Bundle.main`) runs on the main actor; the two closures hop onto
/// MainActor for every call since `GhosttyConfigFile` is main-actor-bound.
@MainActor
extension GhosttyTerminalSettingsClient {
  /// Build the live client. Both closures hop to MainActor and construct a
  /// fresh `GhosttyConfigFile` per call — the type is a lightweight value
  /// wrapper over FileManager / environment, so per-call construction
  /// sidesteps the `@Sendable` capture issue (a `@MainActor`-isolated
  /// struct can't be captured into a `@Sendable` closure) without leaking
  /// any state across calls.
  static func appLive() -> GhosttyTerminalSettingsClient {
    GhosttyTerminalSettingsClient(
      load: {
        try await MainActor.run { try GhosttyConfigFile().load() }
      },
      apply: { draft in
        try await MainActor.run { try GhosttyConfigFile().apply(draft) }
      }
    )
  }
}
