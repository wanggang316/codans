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

  /// Runs the exact host-side script under the local `/bin/sh`, so the shell
  /// half of the protocol is exercised, not just the parser.
  @Test
  func scriptOutputRoundTripsThroughLocalShell() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("manifest-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let makefile = "build: ## Build\n\tgo build\n"
    try makefile.write(to: directory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    try "".write(to: directory.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)

    let process = Process()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments =
      ["-c", RemoteManifestReader.script, "sh", directory.path, "package.json", "Makefile"]
      + [RemoteManifestReader.presenceSeparator, "yarn.lock", "bun.lockb"]
    process.standardOutput = stdout
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let snapshot = RemoteManifestReader.parse(String(decoding: data, as: UTF8.self))
    #expect(process.terminationStatus == 0)
    #expect(snapshot.contents == ["Makefile": makefile])
    #expect(snapshot.presentPaths == ["Makefile", "yarn.lock"])
  }

  @Test
  func readerUsesOneSSHCallAndFailureYieldsEmptySnapshot() async {
    let runner = RecordingCommandRunner(outcomes: [.timedOut])
    let reader = RemoteManifestReader(host: RemoteHost(alias: "devbox"), runner: runner)
    let snapshot = await reader.read(
      ManifestRequest(contentPaths: ["package.json"], presencePaths: ["yarn.lock"]), in: "/srv/app")
    #expect(snapshot == ManifestSnapshot())
    let calls = await runner.calls
    #expect(calls.count == 1)
    #expect(calls.first?.executable.path == "/usr/bin/ssh")
    #expect(calls.first?.arguments.last?.contains("/srv/app") == true)
  }
}

struct LocalManifestReaderTests {
  @Test
  func readsContentsAndProbesPresence() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("manifest-local-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try #"{"scripts":{"dev":"vite"}}"#.write(
      to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "".write(to: directory.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)

    let snapshot = await LocalManifestReader().read(
      CommandSuggestionRegistry.standard.request, in: directory.path)
    let groups = CommandSuggestionRegistry.standard.groups(in: snapshot)
    #expect(groups.map(\.source.id) == ["package-json"])
    #expect(groups.first?.suggestions.map(\.command) == ["pnpm run dev"])
  }
}
