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

  /// Live surfaces the sweep reads; `detachSurface` removes them, like the
  /// Ghostty runtime does.
  @MainActor
  private final class FakeHost: ReclaimableSurfaceHost {
    var surfaces: [ReclaimableSurface] = []
    /// Panes whose detach fails as if the surface were already gone.
    var vanished: Set<PaneID> = []
    private(set) var detached: [PaneID] = []

    func reclaimableSurfaces() -> [ReclaimableSurface] { surfaces }

    func detachSurface(for paneID: PaneID) -> CGSize? {
      guard !vanished.contains(paneID), surfaces.contains(where: { $0.paneID == paneID }) else {
        return nil
      }
      surfaces.removeAll { $0.paneID == paneID }
      detached.append(paneID)
      return CGSize(width: 800, height: 600)
    }
  }

  private final class FakeWatcher: DetachedPaneWatching, @unchecked Sendable {
    func start() {}
    func stop() {}
  }

  @MainActor
  private final class Harness {
    let temp = TempFile()
    let manager: HierarchyManager
    let engine: TerminalEngine
    let host = FakeHost()
    var watched: [PaneID] = []
    var detachedNotices: [PaneID] = []

    init() {
      let store = CatalogStore(fileURL: temp.url)
      manager = HierarchyManager(catalog: .default, store: store, runtime: FakeHierarchyRuntime())
      engine = TerminalEngine(store: store, hierarchy: manager)
      engine.reclaimHost = host
      engine.makeDetachedPaneWatcher = { [unowned self] paneID, _ in
        self.watched.append(paneID)
        return FakeWatcher()
      }
      engine.onSurfaceAttachmentChanged = { [unowned self] paneID, attached in
        if !attached { self.detachedNotices.append(paneID) }
      }
    }

    func seedPanes(_ count: Int) async throws -> [PaneID] {
      let projectID = manager.addProject(name: "p", rootPath: "/", gitRoot: "/")
      let worktreeID = try manager.createWorktree(
        in: projectID, name: "w", path: "/w", branch: "main")
      var panes: [PaneID] = []
      for _ in 0..<count {
        let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
        panes.append(
          try await manager.openPane(
            in: tabID, in: worktreeID, in: projectID, workingDirectory: "/w", initialCommand: nil))
      }
      return panes
    }

    /// A live surface whose pane has `job` as its sampled foreground.
    func addSurface(_ paneID: PaneID, displayed: Bool = false, job: ForegroundJob?) {
      host.surfaces.append(ReclaimableSurface(paneID: paneID, isDisplayed: displayed, isReady: true))
      if let job { engine.processForegroundSample(paneID: paneID, next: job, now: Date()) }
    }
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

  @Test
  func pressureDetachesEveryHiddenEligibleSurfaceAtOnce() async throws {
    let harness = Harness()
    let panes = try await harness.seedPanes(6)
    let (idleShell, idleAgent, displayed, vetoed, running, unknown) =
      (panes[0], panes[1], panes[2], panes[3], panes[4], panes[5])
    harness.addSurface(idleShell, job: Self.job("zsh"))
    harness.addSurface(idleAgent, job: Self.job("claude", "claude --resume"))
    harness.addSurface(displayed, displayed: true, job: Self.job("zsh"))
    harness.addSurface(vetoed, job: Self.job("zsh"))
    harness.addSurface(running, job: Self.job("make", "make test"))
    harness.addSurface(unknown, job: nil)
    harness.engine.reclaimVeto = { $0 == vetoed }

    // The timed sweep keeps panes that were only just hidden.
    #expect(harness.engine.reclaimIdleSurfaces().isEmpty)
    #expect(harness.host.detached.isEmpty)

    let reclaimed = harness.engine.handleMemoryPressure(.warning)

    let expected: Set<PaneID> = [idleShell, idleAgent]
    #expect(Set(reclaimed) == expected)
    #expect(Set(harness.host.detached) == expected)
    #expect(Set(harness.detachedNotices) == expected)
    #expect(Set(harness.watched) == expected)
    for paneID in panes {
      #expect(harness.engine.isReclaimed(paneID) == expected.contains(paneID))
    }
    #expect(
      Set(harness.host.surfaces.map(\.paneID)) == [displayed, vetoed, running, unknown])
  }

  @Test
  func paneWhoseSurfaceIsGoneIsNotCountedAsReclaimed() async throws {
    let harness = Harness()
    let panes = try await harness.seedPanes(2)
    harness.addSurface(panes[0], job: Self.job("zsh"))
    harness.addSurface(panes[1], job: Self.job("zsh"))
    harness.host.vanished = [panes[1]]

    #expect(harness.engine.handleMemoryPressure(.critical) == [panes[0]])
    #expect(!harness.engine.isReclaimed(panes[1]))
    #expect(harness.detachedNotices == [panes[0]])
  }

  @Test
  func pressureSkipsSurfacesOutsideTheCatalog() {
    let harness = Harness()
    harness.addSurface(PaneID(), job: Self.job("zsh"))
    #expect(harness.engine.handleMemoryPressure(.critical).isEmpty)
    #expect(harness.host.detached.isEmpty)
  }

  @Test
  func pressureAfterFinishIsIgnored() async throws {
    let harness = Harness()
    let panes = try await harness.seedPanes(1)
    harness.addSurface(panes[0], job: Self.job("zsh"))
    harness.engine.finishEventStream()
    #expect(harness.engine.handleMemoryPressure(.warning).isEmpty)
    #expect(harness.host.detached.isEmpty)
  }
}
