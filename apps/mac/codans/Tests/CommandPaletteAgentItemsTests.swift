import CodansCore
import ComposableArchitecture
import Dependencies
import Foundation
import Testing

@testable import Codans

/// `CommandPaletteItems.build` surfaces one "Launch Agent" item per enabled
/// profile plus a single "Hand Off…" row while a Worktree is selected.
@MainActor
struct CommandPaletteAgentItemsTests {
  @Test
  func buildEmitsEnabledProfilesAndTheHandOffRow() {
    var catalog = Catalog()
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    catalog.projects = [project]
    let selection = HierarchySelection(projectID: project.id, worktreeID: worktree.id)

    let build = AgentProfile(kind: .codex, name: "Build", systemImage: "hammer")
    let off = AgentProfile(kind: .claudeCode, isEnabled: false)
    let plain = AgentProfile(kind: .gemini)
    let settings: Settings = {
      var s = Settings()
      s.agents.profiles = [build, off, plain]
      return s
    }()

    let items = withDependencies {
      $0[SettingsWriter.self].readSnapshotSync = { settings }
    } operation: {
      CommandPaletteItems.build(selection: selection, catalog: catalog)
    }

    let launches = items.filter {
      if case .launchAgentProfile = $0.kind { return true }
      return false
    }
    #expect(launches.map(\.title) == ["Launch Agent: Build", "Launch Agent: Gemini CLI"])
    #expect(launches.map(\.icon) == ["hammer", "sparkles"])
    #expect(launches.map(\.subtitle) == ["Codex", "Gemini CLI"])
    let ids = launches.compactMap { item -> UUID? in
      if case .launchAgentProfile(let p, let w, let id) = item.kind, p == project.id, w == worktree.id {
        return id
      }
      return nil
    }
    #expect(ids == [build.id, plain.id])

    let handOff = items.filter { $0.kind == .handOff }
    #expect(handOff.count == 1)
    #expect(handOff.first?.subtitle == "wt")
  }

  @Test
  func nothingIsEmittedWithoutAWorktreeSelection() {
    let items = withDependencies {
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    } operation: {
      CommandPaletteItems.build(
        selection: HierarchySelection(projectID: nil, worktreeID: nil), catalog: Catalog())
    }
    let agentItems = items.filter {
      switch $0.kind {
      case .launchAgentProfile, .handOff: return true
      default: return false
      }
    }
    #expect(agentItems.isEmpty)
  }
}
