import CodansCore
import ComposableArchitecture
import Foundation

/// Reads the Code Host aliases from Settings › Code Hosts (ADR 0005). The resolver checks
/// them before any other step. Read at fetch time, so a changed list applies to the next
/// fetch without new action payloads.
nonisolated struct CodeHostAliasesClient: Sendable {
  var aliases: @Sendable () async -> [CodeHostAlias]
}

extension CodeHostAliasesClient {
  @MainActor
  static func live(settings: SettingsStore) -> CodeHostAliasesClient {
    CodeHostAliasesClient { [weak settings] in
      await MainActor.run { settings?.settings.general.codeHostAliases ?? [] }
    }
  }
}

extension CodeHostAliasesClient: DependencyKey {
  /// No aliases until the app wires the live client.
  static let liveValue = CodeHostAliasesClient { [] }
  static let testValue = CodeHostAliasesClient { [] }
}
