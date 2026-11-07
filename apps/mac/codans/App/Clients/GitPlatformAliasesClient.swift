import CodansCore
import ComposableArchitecture
import Foundation

/// Reads the Git Platform aliases from Settings › Git Platforms (ADR 0005). The resolver checks
/// them before any other step. Read at fetch time, so a changed list applies to the next
/// fetch without new action payloads.
nonisolated struct GitPlatformAliasesClient: Sendable {
  var aliases: @Sendable () async -> [GitPlatformAlias]
}

extension GitPlatformAliasesClient {
  @MainActor
  static func live(settings: SettingsStore) -> GitPlatformAliasesClient {
    GitPlatformAliasesClient { [weak settings] in
      await MainActor.run { settings?.settings.general.gitPlatformAliases ?? [] }
    }
  }
}

extension GitPlatformAliasesClient: DependencyKey {
  /// No aliases until the app wires the live client.
  static let liveValue = GitPlatformAliasesClient { [] }
  static let testValue = GitPlatformAliasesClient { [] }
}
