import Foundation

/// One ecosystem's command detector. The extension point of the feature:
/// supporting a new build tool means one new conforming type registered in
/// `CommandSuggestionRegistry.standard` — readers, UI and adoption stay as is.
///
/// Implementations must be pure: everything they may look at is declared in
/// `request` and handed over in the snapshot, so they are testable with
/// literal fixtures and run unchanged for remote (SSH) projects.
public nonisolated protocol CommandSuggestionParser: Sendable {
  var source: CommandSuggestionSource { get }
  var request: ManifestRequest { get }
  /// Suggestions in display order. Empty when the ecosystem is absent or its
  /// manifest does not parse — a broken manifest must never fail the scan.
  func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion]
}

/// Ordered set of parsers the Commands pane consults.
public nonisolated struct CommandSuggestionRegistry: Sendable {
  public var parsers: [any CommandSuggestionParser]

  public init(parsers: [any CommandSuggestionParser]) {
    self.parsers = parsers
  }

  /// Built-in parsers, in `+` menu order: script runners people define entries
  /// in first, fixed toolchain commands last.
  public static let standard = CommandSuggestionRegistry(parsers: [
    PackageJSONParser(),
    DenoTaskParser(),
    ComposerScriptParser(),
    MakefileParser(),
    JustfileParser(),
    TaskfileParser(),
    MiseTaskParser(),
    PyprojectParser(),
    ComposeParser(),
    CargoParser(),
    GoModuleParser(),
    SwiftPackageParser(),
  ])

  /// Everything every parser wants, so a reader answers in one round trip.
  public var request: ManifestRequest {
    parsers.reduce(ManifestRequest()) { $0.merged(with: $1.request) }
  }

  /// Non-empty groups: the root's in registry order, then each subdirectory's
  /// (see `ManifestSnapshot.directories`). Duplicate entry names within one
  /// group collapse to the first occurrence.
  ///
  /// A nested group is titled with the manifest's full relative path
  /// (`packages/web/package.json`) and its commands `cd` into that directory
  /// first, so they run from the worktree root like every other script.
  public func groups(in snapshot: ManifestSnapshot) -> [CommandSuggestionGroup] {
    snapshot.directories.flatMap { directory in
      let view = snapshot.scoped(to: directory)
      return parsers.compactMap { parser -> CommandSuggestionGroup? in
        var seen = Set<String>()
        var suggestions = parser.suggestions(in: view).filter { seen.insert($0.name).inserted }
        guard !suggestions.isEmpty else { return nil }
        var source = parser.source
        if !directory.isEmpty {
          source = CommandSuggestionSource(
            id: "\(directory)/\(source.id)", displayName: "\(directory)/\(source.displayName)")
          let cd = "cd \(CommandSuggestionToken.render(directory)) && "
          for index in suggestions.indices {
            suggestions[index].source = source
            suggestions[index].command = cd + suggestions[index].command
          }
        }
        return CommandSuggestionGroup(source: source, suggestions: suggestions)
      }
    }
  }
}
