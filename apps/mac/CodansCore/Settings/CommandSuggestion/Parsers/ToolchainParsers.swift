import Foundation

/// Toolchains with no per-project script table: the manifest's presence alone
/// implies the standard verbs. Each parser only needs a presence probe.
nonisolated enum ToolchainCommands {
  static func suggestions(
    source: CommandSuggestionSource,
    marker: String,
    snapshot: ManifestSnapshot,
    commands: [(name: String, command: String, kind: ScriptKind)]
  ) -> [CommandSuggestion] {
    guard snapshot.exists(marker) else { return [] }
    return commands.map { CommandSuggestion(source: source, name: $0.name, command: $0.command, kind: $0.kind) }
  }
}

/// `Cargo.toml` → the everyday cargo verbs.
public nonisolated struct CargoParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "cargo", displayName: "Cargo.toml")

  public init() {}

  public var request: ManifestRequest { ManifestRequest(presencePaths: ["Cargo.toml"]) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    ToolchainCommands.suggestions(
      source: source, marker: "Cargo.toml", snapshot: snapshot,
      commands: [
        ("run", "cargo run", .run),
        ("build", "cargo build", .custom),
        ("test", "cargo test", .test),
        ("clippy", "cargo clippy", .lint),
        ("fmt", "cargo fmt", .format),
      ])
  }
}

/// `go.mod` → module-wide go verbs. No `go run`: the module root is often not
/// a main package, and guessing the entry point would be wrong more than right.
public nonisolated struct GoModuleParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "go", displayName: "go.mod")

  public init() {}

  public var request: ManifestRequest { ManifestRequest(presencePaths: ["go.mod"]) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    ToolchainCommands.suggestions(
      source: source, marker: "go.mod", snapshot: snapshot,
      commands: [
        ("build", "go build ./...", .custom),
        ("test", "go test ./...", .test),
        ("vet", "go vet ./...", .lint),
        ("fmt", "gofmt -l -w .", .format),
      ])
  }
}

/// `Package.swift` → SwiftPM verbs.
public nonisolated struct SwiftPackageParser: CommandSuggestionParser {
  public let source = CommandSuggestionSource(id: "swiftpm", displayName: "Package.swift")

  public init() {}

  public var request: ManifestRequest { ManifestRequest(presencePaths: ["Package.swift"]) }

  public func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
    ToolchainCommands.suggestions(
      source: source, marker: "Package.swift", snapshot: snapshot,
      commands: [
        ("run", "swift run", .run),
        ("build", "swift build", .custom),
        ("test", "swift test", .test),
      ])
  }
}
