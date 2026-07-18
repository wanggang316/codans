import ComposableArchitecture
import Foundation
import CodansCore

/// TCA dependency-injection bridge over `EditorService`. Closes over the live
/// `LiveEditorService` built from the app's `SettingsStore`; callers dispatch
/// `describe` / `resolve` / `open` through closures without importing the service
/// type directly.
///
/// The service does not see `ProjectID`. Per-Project editor overrides are resolved at the
/// caller layer (TCA reducer or IPC handler) and handed to the service as an `EditorID?` via
/// the `preferred` parameter.
nonisolated struct EditorClient: Sendable {
  var describe: @Sendable () async -> [EditorDescriptor]
  var resolve: @Sendable (_ preferred: EditorID?) async throws -> EditorDescriptor
  var open: @Sendable (_ directory: URL, _ preferred: EditorID?) async throws -> EditorChoice
  /// Invalidates the service-level cache backing `describe()`. Settings panes and the IPC
  /// `editor.describe` handler call this on appear so newly-installed editors surface.
  var clearCache: @Sendable () async -> Void
}

extension EditorClient {
  /// Constructs a client that forwards to a `LiveEditorService`. Captures the
  /// `SettingsStore` weakly so the client can outlive a scoped store in tests.
  @MainActor
  static func live(settings: SettingsStore?) -> EditorClient {
    let service = LiveEditorService(
      launcher: LiveAppLauncher(),
      globalDefault: { [weak settings] in
        // SettingsStore is @Observable on MainActor; LiveEditorService is an actor
        // with its own executor, so we must hop explicitly rather than assume.
        await MainActor.run { settings?.settings.general.defaultEditorID }
      }
    )
    return EditorClient(
      describe: { await service.describe() },
      resolve: { preferred in try await service.resolve(preferred: preferred) },
      open: { directory, preferred in
        try await service.open(directory: directory, preferred: preferred)
      },
      clearCache: { await service.clearCache() }
    )
  }
}

extension EditorClient: DependencyKey {
  /// `liveValue` is intentionally unusable — missing wiring is a programmer error, not a
  /// silent fallback. `CodansApp.bringUp()` overrides via
  /// `.withDependencies { $0.editorClient = .live(settings:) }`.
  static let liveValue: EditorClient = EditorClient(
    describe: {
      fatalError(
        "EditorClient.liveValue not configured; wire via `.withDependencies` at app startup with `.live(settings:)`"
      )
    },
    resolve: { _ in
      fatalError("EditorClient.liveValue not configured")
    },
    open: { _, _ in
      fatalError("EditorClient.liveValue not configured")
    },
    clearCache: {
      fatalError("EditorClient.liveValue not configured")
    }
  )

  static let testValue: EditorClient = EditorClient(
    describe: unimplemented("EditorClient.describe", placeholder: []),
    resolve: unimplemented(
      "EditorClient.resolve",
      placeholder: TestEditorService.defaultDescriptor
    ),
    open: unimplemented(
      "EditorClient.open",
      placeholder: TestEditorService.defaultChoice
    ),
    clearCache: unimplemented("EditorClient.clearCache")
  )
}

extension DependencyValues {
  var editorClient: EditorClient {
    get { self[EditorClient.self] }
    set { self[EditorClient.self] = newValue }
  }
}
