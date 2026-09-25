import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct CommandSuggestionScanTests {
  private nonisolated static let group = CommandSuggestionGroup(
    source: CommandSuggestionSource(id: "make", displayName: "Makefile"),
    suggestions: [
      CommandSuggestion(
        source: CommandSuggestionSource(id: "make", displayName: "Makefile"),
        name: "build", command: "make build")
    ]
  )

  private func makeStore(
    catalog: Catalog,
    projectID: ProjectID,
    scanned: LockIsolated<[ManifestLocation]>
  ) -> TestStoreOf<ProjectSettingsFeature> {
    TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { catalog }
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.commandSuggestionClient.scan = { location in
        scanned.withValue { $0.append(location) }
        return [Self.group]
      }
    }
  }

  @Test
  func scansTheSelectedWorktreeAndStoresGroups() async {
    let worktree = Worktree(name: "feat", path: "/repo/.worktrees/feat")
    let project = Project(
      name: "repo", rootPath: "/repo", worktrees: [worktree], selectedWorktreeID: worktree.id)
    let scanned = LockIsolated<[ManifestLocation]>([])
    let store = makeStore(catalog: Catalog(projects: [project]), projectID: project.id, scanned: scanned)

    await store.send(.scanCommandSuggestions) {
      $0.isScanningCommandSuggestions = true
    }
    await store.receive(\.commandSuggestionsScanned) {
      $0.commandSuggestions = [Self.group]
      $0.isScanningCommandSuggestions = false
    }
    #expect(scanned.value == [ManifestLocation(directory: "/repo/.worktrees/feat", host: nil)])
  }

  @Test
  func serverProjectScansItsRootOnTheHost() async {
    let host = RemoteHost(alias: "devbox")
    let project = Project(name: "app", rootPath: "/srv/app", remoteHost: host)
    let scanned = LockIsolated<[ManifestLocation]>([])
    let store = makeStore(catalog: Catalog(projects: [project]), projectID: project.id, scanned: scanned)

    await store.send(.scanCommandSuggestions) {
      $0.isScanningCommandSuggestions = true
    }
    await store.receive(\.commandSuggestionsScanned) {
      $0.commandSuggestions = [Self.group]
      $0.isScanningCommandSuggestions = false
    }
    #expect(scanned.value == [ManifestLocation(directory: "/srv/app", host: host)])
  }

  @Test
  func missingProjectClearsSuggestionsWithoutScanning() async {
    var initial = ProjectSettingsFeature.State(projectID: ProjectID())
    initial.commandSuggestions = [Self.group]
    let store = TestStore(initialState: initial) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
    }

    await store.send(.scanCommandSuggestions) {
      $0.commandSuggestions = []
    }
  }
}

struct RemoteManifestReaderTests {
  @Test
  func parseSplitsFileSectionsAndPresenceMarkers() {
    let output = """
      Welcome to devbox
      ===CODANS-MANIFEST package.json===
      { "scripts": {} }
      ===CODANS-PRESENT pnpm-lock.yaml===
      ===CODANS-MANIFEST Makefile===
      build:
      \tgo build

      ===CODANS-PRESENT Cargo.toml===

      """
    let snapshot = RemoteManifestReader.parse(output)
    #expect(snapshot["package.json"] == #"{ "scripts": {} }"#)
    #expect(snapshot["Makefile"] == "build:\n\tgo build\n")
    #expect(snapshot.exists("pnpm-lock.yaml"))
    #expect(snapshot.exists("Cargo.toml"))
    #expect(snapshot.contents.count == 2)
  }

  /// Runs the exact host-side script under the local `/bin/sh` against a real
  /// tree, so the `find` pruning half of the protocol is exercised too.
  @Test
  func scriptWalksTheTreeLikeTheLocalReader() async throws {
    let root = try ManifestFixtureTree.make()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = CommandSuggestionRegistry.standard.request

    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", RemoteManifestReader.script(for: request, scope: .standard), "sh", root.path]
    process.standardOutput = stdout
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let remote = RemoteManifestReader.parse(String(decoding: data, as: UTF8.self))
    let local = await LocalManifestReader().read(request, in: root.path, scope: .standard)
    #expect(remote == local)
    #expect(remote.presentPaths == ManifestFixtureTree.expectedPaths)
    #expect(remote["apps/web/package.json"] == ManifestFixtureTree.webManifest)
  }

  @Test
  func readerUsesOneSSHCallAndFailureYieldsEmptySnapshot() async {
    let runner = RecordingCommandRunner(outcomes: [.timedOut])
    let reader = RemoteManifestReader(host: RemoteHost(alias: "devbox"), runner: runner)
    let snapshot = await reader.read(
      ManifestRequest(contentPaths: ["package.json"], presencePaths: ["yarn.lock"]), in: "/srv/app",
      scope: .standard)
    #expect(snapshot == ManifestSnapshot())
    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(calls.first?.executable.path == "/usr/bin/ssh")
    #expect(calls.first?.arguments.last?.contains("/srv/app") == true)
  }
}

struct LocalManifestReaderTests {
  @Test
  func readsTheTreeWithinScope() async throws {
    let root = try ManifestFixtureTree.make()
    defer { try? FileManager.default.removeItem(at: root) }

    let snapshot = await LocalManifestReader().read(
      CommandSuggestionRegistry.standard.request, in: root.path, scope: .standard)
    #expect(snapshot.presentPaths == ManifestFixtureTree.expectedPaths)
    let groups = CommandSuggestionRegistry.standard.groups(in: snapshot)
    #expect(groups.map(\.source.displayName) == ["package.json", "apps/web/package.json", "services/api/Makefile"])
    #expect(groups[1].suggestions.map(\.command) == ["cd apps/web && pnpm run dev"])
  }
}

/// A small monorepo on disk: manifests at the root, two levels down, and in
/// places the scope must skip (too deep, hidden, dependency cache).
enum ManifestFixtureTree {
  static let webManifest = #"{"scripts":{"dev":"vite"}}"#
  static let expectedPaths: Set<String> = [
    "package.json", "pnpm-lock.yaml", "apps/web/package.json", "services/api/Makefile",
  ]

  static func make() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-tree-\(UUID().uuidString)")
    let files: [String: String] = [
      "package.json": #"{"scripts":{"build":"turbo build"}}"#,
      "pnpm-lock.yaml": "",
      "apps/web/package.json": webManifest,
      "services/api/Makefile": "run:\n\tgo run .\n",
      // Excluded: dependency cache, hidden directory, and deeper than 3 levels.
      "node_modules/left-pad/package.json": "{}",
      ".cache/package.json": "{}",
      "a/b/c/d/package.json": "{}",
    ]
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
  }
}
