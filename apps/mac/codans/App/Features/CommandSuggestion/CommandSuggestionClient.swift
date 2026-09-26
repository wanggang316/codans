import ComposableArchitecture
import CodansCore
import Foundation

/// TCA bridge for the Commands pane's `+` menu suggestions: pick the reader
/// for the location, answer the registry's merged request in one read, parse.
nonisolated struct CommandSuggestionClient: Sendable {
  var scan: @Sendable (_ location: ManifestLocation) async -> [CommandSuggestionGroup]
}

extension CommandSuggestionClient {
  static func live(
    registry: CommandSuggestionRegistry = .standard,
    scope: ManifestScope = .standard
  ) -> CommandSuggestionClient {
    CommandSuggestionClient(scan: { location in
      let reader: any ManifestReader =
        location.host.map { RemoteManifestReader(host: $0) } ?? LocalManifestReader()
      let snapshot = await reader.read(registry.request, in: location.directory, scope: scope)
      return registry.groups(in: snapshot)
    })
  }
}

extension CommandSuggestionClient: DependencyKey {
  static let liveValue = CommandSuggestionClient.live()

  /// Inert rather than `unimplemented`: the worktree header scans on
  /// appear, so any app-hosted test that renders it would otherwise fail.
  static let testValue = CommandSuggestionClient(scan: { _ in [] })
}

extension DependencyValues {
  var commandSuggestionClient: CommandSuggestionClient {
    get { self[CommandSuggestionClient.self] }
    set { self[CommandSuggestionClient.self] = newValue }
  }
}
