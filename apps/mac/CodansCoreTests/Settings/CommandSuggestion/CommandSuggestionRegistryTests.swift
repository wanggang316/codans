import Foundation
import Testing

@testable import CodansCore

struct CommandSuggestionRegistryTests {
  /// Minimal third-party parser: proves the registry is open for extension
  /// without touching any built-in.
  private struct StubParser: CommandSuggestionParser {
    let source = CommandSuggestionSource(id: "stub", displayName: "Stub")
    var names: [String]
    var request: ManifestRequest {
      ManifestRequest(contentPaths: ["stub.txt", "package.json"], presencePaths: ["stub.lock"])
    }
    func suggestions(in snapshot: ManifestSnapshot) -> [CommandSuggestion] {
      guard snapshot["stub.txt"] != nil else { return [] }
      return names.map { CommandSuggestion(source: source, name: $0, command: "stub \($0)") }
    }
  }

  @Test
  func requestIsDeduplicatedUnionAcrossParsers() {
    let registry = CommandSuggestionRegistry(parsers: [PackageJSONParser(), StubParser(names: [])])
    let request = registry.request
    #expect(request.contentPaths == ["package.json", "stub.txt"])
    #expect(request.presencePaths.contains("pnpm-lock.yaml"))
    #expect(request.presencePaths.last == "stub.lock")
  }

  @Test
  func contentPathsAreNotRepeatedAsPresenceProbes() {
    let merged = ManifestRequest(contentPaths: ["a"]).merged(with: ManifestRequest(presencePaths: ["a", "b"]))
    #expect(merged.contentPaths == ["a"])
    #expect(merged.presencePaths == ["b"])
  }

  @Test
  func groupsKeepRegistryOrderDropEmptyAndDeduplicateNames() {
    let registry = CommandSuggestionRegistry(parsers: [
      StubParser(names: ["a", "b", "a"]),
      PackageJSONParser(),
      CargoParser(),
    ])
    let groups = registry.groups(
      in: ManifestSnapshot(contents: ["stub.txt": ""], presentPaths: ["Cargo.toml"]))
    #expect(groups.map(\.source.id) == ["stub", "cargo"])
    #expect(groups.first?.suggestions.map(\.name) == ["a", "b"])
  }

  @Test
  func standardRegistryCoversEveryBuiltInSource() {
    let ids = CommandSuggestionRegistry.standard.parsers.map(\.source.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.first == "package-json")
  }

  @Test
  func snapshotContentsImplyPresence() {
    let snapshot = ManifestSnapshot(contents: ["package.json": "{}"])
    #expect(snapshot.exists("package.json"))
  }
}

struct ScriptKindInferenceTests {
  @Test
  func classifiesByLeadingSegment() {
    let cases: [(String, ScriptKind)] = [
      ("dev", .run), ("start:prod", .run), ("test", .test), ("test:unit", .test), ("e2e", .test),
      ("lint-fix", .lint), ("typecheck", .lint), ("fmt", .format), ("format", .format),
      ("deploy", .deploy), ("release.patch", .deploy), ("build", .custom), ("Test", .test),
    ]
    for (name, kind) in cases {
      #expect(ScriptKindInference.kind(forEntryName: name) == kind, "\(name)")
    }
  }
}

struct CommandSuggestionAdoptionTests {
  private let source = CommandSuggestionSource(id: "package-json", displayName: "package.json")

  private func suggestion(_ name: String, _ command: String) -> CommandSuggestion {
    CommandSuggestion(source: source, name: name, command: command)
  }

  @Test
  func runMaterializesVirtualBuiltinRunAtFront() {
    let existing = [ScriptDefinition(kind: .test, command: "npm test")]
    let result = CommandSuggestionAdoption.adopt(suggestion("dev", "pnpm run dev"), into: existing)
    #expect(result.scripts.count == 2)
    #expect(result.scripts[0].id == ScriptDefinition.builtinRunID)
    #expect(result.scripts[0].command == "pnpm run dev")
    #expect(result.scripts[0].name == "dev")
    #expect(result.scripts[0].keyboardShortcut == ScriptDefinition.builtinRun.keyboardShortcut)
    #expect(result.scriptID == ScriptDefinition.builtinRunID)
  }

  @Test
  func runFillsAnExistingBlankRun() {
    let blank = ScriptDefinition(kind: .run, command: "  ")
    let result = CommandSuggestionAdoption.adopt(suggestion("start", "npm run start"), into: [blank])
    #expect(result.scripts.count == 1)
    #expect(result.scripts[0].id == blank.id)
    #expect(result.scripts[0].command == "npm run start")
  }

  @Test
  func takenKindFallsBackToCustom() {
    let run = ScriptDefinition(kind: .run, command: "make run")
    let test = ScriptDefinition(kind: .test, command: "make test")
    var result = CommandSuggestionAdoption.adopt(suggestion("dev", "npm run dev"), into: [run, test])
    #expect(result.scripts.last?.kind == .custom)
    #expect(result.scripts.last?.name == "dev")
    #expect(result.scripts.last?.id == result.scriptID)

    result = CommandSuggestionAdoption.adopt(suggestion("test:unit", "npm run test:unit"), into: [run, test])
    #expect(result.scripts.last?.kind == .custom)
  }

  @Test
  func freeKindIsKept() {
    let result = CommandSuggestionAdoption.adopt(suggestion("lint", "npm run lint"), into: [])
    #expect(result.scripts.map(\.kind) == [.lint])
  }

  @Test
  func mappedIconIsStoredOnlyWhenItDiffersFromTheKindDefault() {
    // `docker:up` → docker mark on a custom script.
    var result = CommandSuggestionAdoption.adopt(suggestion("docker:up", "make docker:up"), into: [])
    #expect(result.scripts.last?.systemImage == "mark:docker")
    // `lint` → checklist symbol, not the lint kind's magnifying glass.
    result = CommandSuggestionAdoption.adopt(suggestion("lint", "npm run lint"), into: [])
    #expect(result.scripts.last?.systemImage == "checklist")
    // `dev` → play.fill, which is Run's own default: nothing stored.
    result = CommandSuggestionAdoption.adopt(suggestion("dev", "npm run dev"), into: [])
    #expect(result.scripts.first?.systemImage == nil)
  }

  @Test
  func fillingABlankRunKeepsTheUsersIcon() {
    let blank = ScriptDefinition(kind: .run, systemImage: "bolt.fill")
    let result = CommandSuggestionAdoption.adopt(suggestion("start", "npm run start"), into: [blank])
    #expect(result.scripts[0].systemImage == "bolt.fill")
  }

  @Test
  func adoptedWhenAnyScriptRunsTheSameCommand() {
    let scripts = [ScriptDefinition(kind: .custom, command: "npm run dev\n")]
    #expect(CommandSuggestionAdoption.isAdopted(suggestion("dev", "npm run dev"), in: scripts))
    #expect(!CommandSuggestionAdoption.isAdopted(suggestion("build", "npm run build"), in: scripts))
  }
}
