import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct TerminalEngineMemoryPressureTests {
  private final class TempFile {
    let url = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  private static func job(_ argv0: String, _ commandLine: String? = nil) -> ForegroundJob {
    ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(
          pid: 100, parentPID: 1, processGroupID: 100,
          argv0: argv0, commandLine: commandLine ?? argv0)
      ])
  }

  private static func sample(
    _ paneID: PaneID,
    displayed: Bool = false,
    job: ForegroundJob? = TerminalEngineMemoryPressureTests.job("zsh"),
    remote: Bool = false
  ) -> TerminalEngine.LiveSurfaceSample {
    .init(paneID: paneID, isDisplayed: displayed, isReady: true, foregroundJob: job, isRemote: remote)
  }

  private let temp = TempFile()

  private func makeEngine() -> (TerminalEngine, HierarchyManager) {
    let store = CatalogStore(fileURL: temp.url)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: FakeHierarchyRuntime())
    return (TerminalEngine(store: store, hierarchy: manager), manager)
  }

  private func seedPanes(_ count: Int, in manager: HierarchyManager) async throws -> [PaneID] {
    let projectID = manager.addProject(name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, name: "w", path: "/w", branch: "main")
    var panes: [PaneID] = []
    for _ in 0..<count {
      let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
      panes.append(
        try await manager.openPane(
          in: tabID, in: worktreeID, in: projectID, workingDirectory: "/w", initialCommand: nil))
    }
    return panes
  }

  @Test
  func pressureReclaimsEveryHiddenEligibleSurfaceAtOnce() async throws {
    let (engine, manager) = makeEngine()
    let panes = try await seedPanes(7, in: manager)
    let (idleShell, idleAgent, displayed, remote, vetoed, running, unknown) =
      (panes[0], panes[1], panes[2], panes[3], panes[4], panes[5], panes[6])
    let claude = Self.job("claude", "claude --resume")
    engine.liveSurfaceSamplesOverride = {
      [
        Self.sample(idleShell),
        Self.sample(idleAgent, job: claude),
        Self.sample(displayed, displayed: true),
        Self.sample(remote, remote: true),
        Self.sample(vetoed),
        Self.sample(running, job: Self.job("make", "make test")),
        Self.sample(unknown, job: nil),
      ]
    }
    engine.reclaimVeto = { $0 == vetoed }

    // The timed sweep keeps panes that were only just hidden.
    #expect(engine.reclaimIdleSurfaces().isEmpty)

    let reclaimed = engine.handleMemoryPressure(.warning)
    #expect(Set(reclaimed) == [idleShell, idleAgent])
  }

  @Test
  func pressureSkipsSurfacesOutsideTheCatalog() {
    let (engine, _) = makeEngine()
    engine.liveSurfaceSamplesOverride = { [Self.sample(PaneID())] }
    #expect(engine.handleMemoryPressure(.critical).isEmpty)
  }

  @Test
  func pressureAfterFinishIsIgnored() async throws {
    let (engine, manager) = makeEngine()
    let panes = try await seedPanes(1, in: manager)
    engine.liveSurfaceSamplesOverride = { [Self.sample(panes[0])] }
    engine.finishEventStream()
    #expect(engine.handleMemoryPressure(.warning).isEmpty)
  }
}
