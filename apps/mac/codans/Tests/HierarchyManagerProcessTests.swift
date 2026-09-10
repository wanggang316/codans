import Foundation
import Testing

@testable import Codans
@testable import CodansCore

@MainActor
struct HierarchyManagerProcessTests {
  @Test func focusedRunRetiresAndDoesNotAttributeTheNextCommand() {
    let f = fixture()
    f.manager.recordProcessLaunch(paneID: f.pane.id, name: "Dev", kind: .run, now: time)
    #expect(f.manager.processEntries(in: f.worktree.id).isEmpty)
    sample(f, name: "node")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "Dev")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.processName == "node")
    sample(f, name: "zsh")
    sample(f, name: "python")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "python")
  }

  @Test func missingSamplesRetireAgentAndPIDReuseChangesIdentity() throws {
    let f = fixture()
    sample(f, name: "codex")
    let first = try #require(f.manager.processEntries(in: f.worktree.id).first)
    sample(f, name: "codex")
    #expect(f.manager.processEntries(in: f.worktree.id).count == 1)
    #expect(f.manager.isCurrentProcess(first))
    sample(f, name: "codex", birth: time.addingTimeInterval(5))
    #expect(!f.manager.isCurrentProcess(first))
    f.manager.updateProcessSample(
      paneID: f.pane.id, job: .init(processGroupID: 0, processes: []), now: time)
    #expect(f.manager.processEntries(in: f.worktree.id).isEmpty)
  }

  @Test func launchTimeoutDoesNotAttributeAnUnrelatedCommand() {
    let f = fixture()
    f.manager.recordProcessLaunch(
      paneID: f.pane.id, name: "Failed", kind: .run, now: time.addingTimeInterval(-16))
    sample(f, name: "python")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "python")
  }

  @Test func focusedDispatchIntoBusyPaneDoesNotRenameExistingProcess() throws {
    let f = fixture()
    sample(f, name: "codex")
    let original = try #require(f.manager.processEntries(in: f.worktree.id).first)
    f.manager.recordProcessLaunch(
      paneID: f.pane.id, name: "Dev", kind: .run, now: time, requiresIdle: true)
    sample(f, name: "codex")
    #expect(f.manager.isCurrentProcess(original))
  }

  @Test func processReplacementWithoutShellSampleRetiresFocusedRun() {
    let f = fixture()
    f.manager.recordProcessLaunch(paneID: f.pane.id, name: "Dev", kind: .run, now: time)
    sample(f, name: "node")
    sample(f, name: "python", birth: time.addingTimeInterval(2))
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "python")
    sample(f, name: "python", birth: time.addingTimeInterval(2))
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "python")
  }

  @Test func agentReplacementByOrdinaryCommandUpdatesEntry() {
    let f = fixture()
    sample(f, name: "codex")
    sample(f, name: "python", birth: time.addingTimeInterval(2))
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "python")
  }

  @Test func focusedLaunchWithoutSampleRejectsAnOlderProcess() {
    let f = fixture()
    f.manager.recordProcessLaunch(
      paneID: f.pane.id, name: "Dev", kind: .run, now: time, requiresIdle: true)
    #expect(!f.manager.processRegistry.launches.isEmpty)
    sample(f, name: "zsh")
    f.manager.recordProcessLaunch(
      paneID: f.pane.id, name: "Dev", kind: .run, now: time, requiresIdle: true)
    sample(f, name: "node", birth: time.addingTimeInterval(-1))
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "node")
    #expect(f.manager.processRegistry.launches.isEmpty)
  }

  @Test func remoteFailureHidesThenRestoresTheSameRunWithinBound() {
    let f = fixture()
    f.manager.recordProcessLaunch(paneID: f.pane.id, name: "Dev", kind: .run, now: time)
    sample(f, name: "node")
    f.manager.processRegistry.suspend(f.pane.id, now: time)
    #expect(f.manager.processEntries(in: f.worktree.id).isEmpty)
    sample(f, name: "node")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "Dev")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.processName == "node")
    f.manager.processRegistry.suspend(f.pane.id, now: time)
    f.manager.processRegistry.suspend(f.pane.id, now: time.addingTimeInterval(31))
    sample(f, name: "node")
    #expect(f.manager.processEntries(in: f.worktree.id).first?.name == "node")
  }

  @Test func coldStartDoesNotTrustPersistedRunPaneOrAgent() {
    let f = fixture()
    f.manager.setRunScriptPane(worktreeID: f.worktree.id, scriptID: UUID(), paneID: f.pane.id)
    sample(f, name: "node")
    let restored = HierarchyManager(
      catalog: f.manager.catalog, store: f.store, runtime: FakeHierarchyRuntime())
    #expect(restored.processEntries(in: f.worktree.id).isEmpty)
  }

  @Test(arguments: ["pane", "tab", "archive", "worktree", "project"])
  func teardownRejectsLateSamples(action: String) throws {
    let f = fixture()
    sample(f, name: "codex")
    #expect(f.manager.processEntries(in: WorktreeID()).isEmpty)
    switch action {
    case "pane":
      try f.manager.closePane(f.pane.id, in: f.tab.id, in: f.worktree.id, in: f.project.id)
    case "tab": try f.manager.closeTab(f.tab.id, in: f.worktree.id, in: f.project.id)
    case "archive": try f.manager.setWorktreeArchived(worktreeID: f.worktree.id, archived: true)
    case "worktree": try f.manager.removeWorktree(f.worktree.id, from: f.project.id)
    default: try f.manager.removeProject(f.project.id)
    }
    #expect(f.manager.processRegistry.entries.isEmpty)
    sample(f, name: "codex")
    #expect(f.manager.processEntries(in: f.worktree.id).isEmpty)
    if action == "archive" {
      try f.manager.setWorktreeArchived(worktreeID: f.worktree.id, archived: false)
      #expect(f.manager.processEntries(in: f.worktree.id).isEmpty)
    }
  }

  @Test func manualNpmForegroundGroupIsVisibleWithoutLaunchMetadata() throws {
    let f = fixture()
    let processes = ["npm run tauri dev", "sh", "node", "cargo", "handbox"].enumerated().map {
      ForegroundProcess(
        pid: Int32(100 + $0.offset), parentPID: Int32(99 + $0.offset), processGroupID: 100,
        argv0: $0.element, commandLine: $0.element, startedAt: time)
    }
    f.manager.updateProcessSample(
      paneID: f.pane.id, job: .init(processGroupID: 100, processes: processes), now: time)
    let entry = try #require(f.manager.processEntries(in: f.worktree.id).first)
    #expect(f.manager.processEntries(in: f.worktree.id).count == 1)
    #expect(entry.name == "npm run tauri dev")
    #expect(entry.pid == 100)
    #expect(entry.kind == .command)
    sample(f, name: "zsh")
    #expect(f.manager.processEntries(in: f.worktree.id).isEmpty)
  }

  @Test func coldStartRediscoversManualCommandOnlyAfterLiveSample() {
    let f = fixture()
    sample(f, name: "npm")
    let restored = HierarchyManager(
      catalog: f.manager.catalog, store: f.store, runtime: FakeHierarchyRuntime())
    #expect(restored.processEntries(in: f.worktree.id).isEmpty)
    restored.updateProcessSample(
      paneID: f.pane.id,
      job: .init(
        processGroupID: 100,
        processes: [
          .init(
            pid: 100, parentPID: 1, processGroupID: 100, argv0: "npm", commandLine: "npm",
            startedAt: time)
        ]), now: time)
    #expect(restored.processEntries(in: f.worktree.id).first?.name == "npm")
  }

  private let time = Date(timeIntervalSince1970: 1_000)
  private typealias Fixture = (
    manager: HierarchyManager, store: RecordingCatalogStore, pane: Pane, tab: Tab,
    worktree: Worktree, project: Project
  )

  private func sample(_ f: Fixture, name: String, birth: Date? = nil) {
    let process = ForegroundProcess(
      pid: 100, parentPID: 1, processGroupID: 100, argv0: name, commandLine: name,
      startedAt: birth ?? time)
    f.manager.updateProcessSample(
      paneID: f.pane.id, job: .init(processGroupID: 100, processes: [process]), now: time)
  }

  private func fixture() -> Fixture {
    let pane = Pane(workingDirectory: "/repo/wt")
    let tab = Tab(splitTree: .init(leaf: pane.id), panes: [pane])
    let worktree = Worktree(name: "feature", path: "/repo/wt", tabs: [tab])
    let project = Project(name: "repo", rootPath: "/repo", gitRoot: "/repo", worktrees: [worktree])
    let store = RecordingCatalogStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        "process-\(UUID()).json"))
    let manager = HierarchyManager(
      catalog: Catalog(projects: [project]), store: store, runtime: FakeHierarchyRuntime())
    return (manager, store, pane, tab, worktree, project)
  }
}
