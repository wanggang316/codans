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

struct NestedManifestTests {
  @Test
  func scopedViewKeepsDirectChildrenAndExposesAncestors() {
    let snapshot = ManifestSnapshot(
      contents: ["package.json": "{}", "packages/web/package.json": "{}", "packages/web/src/x.json": "{}"],
      presentPaths: ["pnpm-lock.yaml"])
    #expect(snapshot.directories == ["", "packages/web", "packages/web/src"])
    let web = snapshot.scoped(to: "packages/web")
    #expect(web.presentPaths == ["package.json"])
    #expect(web.ancestors.count == 2)  // packages, root
    #expect(web.ancestors.last?.exists("pnpm-lock.yaml") == true)
  }

  @Test
  func nestedGroupsUseFullPathTitlesAndCdIntoTheirDirectory() {
    let snapshot = ManifestSnapshot(
      contents: [
        "package.json": #"{ "packageManager": "pnpm@9", "scripts": { "dev": "turbo dev" } }"#,
        "apps/web/package.json": #"{ "scripts": { "dev": "vite" } }"#,
        "services/api/Makefile": "run:\n\tgo run .\n",
      ])
    let groups = CommandSuggestionRegistry.standard.groups(in: snapshot)
    #expect(groups.map(\.source.displayName) == ["package.json", "apps/web/package.json", "services/api/Makefile"])
    #expect(groups[1].suggestions.first?.command == "cd apps/web && pnpm run dev")
    #expect(groups[2].suggestions.first?.command == "cd services/api && make run")
    // Same entry name in two directories stays two distinct suggestions.
    #expect(groups[0].suggestions.first?.id != groups[1].suggestions.first?.id)
  }

  @Test
  func workspaceMemberInheritsTheRootLockfile() {
    let snapshot = ManifestSnapshot(
      contents: ["packages/ui/package.json": #"{ "scripts": { "build": "tsc" } }"#],
      presentPaths: ["yarn.lock"])
    let groups = CommandSuggestionRegistry.standard.groups(in: snapshot)
    #expect(groups.first?.suggestions.first?.command == "cd packages/ui && yarn run build")
  }

  @Test
  func nearerDeclarationWinsOverAncestorLockfile() {
    let snapshot = ManifestSnapshot(
      contents: ["tools/package.json": #"{ "packageManager": "bun@1", "scripts": { "x": "y" } }"#],
      presentPaths: ["pnpm-lock.yaml"])
    #expect(
      CommandSuggestionRegistry.standard.groups(in: snapshot).first?.suggestions.first?.command
        == "cd tools && bun run x")
  }

  @Test
  func scopeSkipsHiddenAndDependencyDirectories() {
    let scope = ManifestScope.standard
    #expect(scope.shouldDescend(into: "packages"))
    #expect(!scope.shouldDescend(into: "node_modules"))
    #expect(!scope.shouldDescend(into: ".git"))
    #expect(!scope.shouldDescend(into: "target"))
  }
}

struct TransientSuggestionScriptTests {
  private let source = CommandSuggestionSource(id: "package-json", displayName: "package.json")

  @Test
  func idIsStablePerSuggestionAndDistinctAcrossThem() {
    let dev = CommandSuggestion(source: source, name: "dev", command: "pnpm run dev")
    let build = CommandSuggestion(source: source, name: "build", command: "pnpm run build")
    let first = CommandSuggestionAdoption.transientScript(for: dev)
    #expect(first.id == CommandSuggestionAdoption.transientScript(for: dev).id)
    #expect(first.id != CommandSuggestionAdoption.transientScript(for: build).id)
    #expect(first.command == "pnpm run dev")
    #expect(first.target == .newTab)
  }
}

struct GlobalCommandSuggestionsTests {
  @Test
  func groupsAreGitAndGitHubWithUniqueIDs() {
    let groups = GlobalCommandSuggestions.groups
    #expect(groups.map(\.source.displayName) == ["Git", "GitHub CLI", "Docker", "System", "Homebrew"])
    let ids = groups.flatMap(\.suggestions).map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(groups.flatMap(\.suggestions).allSatisfy { $0.icon != nil && $0.kind == .custom })
  }

  @Test
  func nothingDestructiveIsSuggested() {
    let destructive = [
      "reset --hard", "clean -f", "push --force", "push -f", "branch -D", "checkout -- ", "restore ",
      "system prune", "image prune", "volume prune",
      "brew upgrade", "rm -", "docker rm", "down -v", "--volumes",
    ]
    for suggestion in GlobalCommandSuggestions.groups.flatMap(\.suggestions) {
      #expect(!destructive.contains(where: suggestion.command.contains), "\(suggestion.command)")
    }
  }

  @Test
  func adoptingAppendsACustomCommandWithItsIcon() {
    let status = GlobalCommandSuggestions.groups[0].suggestions[0]
    let existing = [ScriptDefinition(kind: .run, command: "make")]
    let result = CommandSuggestionAdoption.adoptGlobal(status, into: existing)
    #expect(result.scripts.count == 2)
    #expect(result.scripts.last?.kind == .custom)
    #expect(result.scripts.last?.name == "Status")
    #expect(result.scripts.last?.command == "git status -sb")
    #expect(result.scripts.last?.systemImage == "list.bullet.rectangle")
    #expect(result.scriptID == result.scripts.last?.id)
  }
}

struct PyprojectParserTests {
  private func suggest(_ text: String, present: Set<String> = []) -> [CommandSuggestion] {
    PyprojectParser().suggestions(in: ManifestSnapshot(contents: ["pyproject.toml": text], presentPaths: present))
  }

  @Test
  func uvProjectRunsEntryPointsAndVerbsThroughUv() {
    let result = suggest(
      """
      [project]
      name = "app"
      dependencies = ["fastapi"]

      [project.scripts]
      serve = "app.main:run"
      "seed-db" = "app.db:seed"

      [dependency-groups]
      dev = ["pytest>=8"]
      """, present: ["uv.lock"])
    #expect(result.map(\.name) == ["serve", "seed-db", "sync", "pytest"])
    #expect(result.map(\.command) == ["uv run serve", "uv run seed-db", "uv sync", "uv run pytest"])
    #expect(result.first?.detail == "app.main:run")
  }

  @Test
  func poetryAndPdmTablesUseTheirOwnRunner() {
    let result = suggest(
      """
      [tool.poetry]
      name = "x"

      [tool.poetry.scripts]
      cli = "x.cli:main"

      [tool.pdm.scripts]
      lint = "ruff check ."
      start = { cmd = "flask run", help = "Dev server" }
      """)
    #expect(result.map(\.command) == ["poetry run cli", "pdm run lint", "pdm run start", "poetry install"])
    #expect(result[2].detail == "flask run")
  }

  @Test
  func entryPointsWithoutAToolRunBare() {
    #expect(suggest("[project.scripts]\nhello = \"pkg:main\"\n").map(\.command) == ["hello"])
  }
}

struct ComposeParserTests {
  @Test
  func stackVerbsThenOneUpPerService() {
    let text = """
      name: shop
      services:
        web:
          image: nginx
          ports:
            - "8080:80"
        "db":
          image: postgres
      volumes:
        data: {}
      """
    let result = ComposeParser().suggestions(in: ManifestSnapshot(contents: ["docker-compose.yml": text]))
    #expect(result.map(\.name) == ["up", "down", "logs", "ps", "web", "db"])
    #expect(result.map(\.command).suffix(2) == ["docker compose up web", "docker compose up db"])
    #expect(result.last?.icon == .mark(.docker))
    #expect(result.first?.icon == .symbol("play.fill"))
  }

  @Test
  func composeYamlWinsOverLegacyName() {
    let snapshot = ManifestSnapshot(contents: [
      "compose.yaml": "services:\n  api:\n    build: .\n", "docker-compose.yml": "services:\n  old:\n    image: x\n",
    ])
    #expect(ComposeParser().suggestions(in: snapshot).last?.name == "api")
  }
}
