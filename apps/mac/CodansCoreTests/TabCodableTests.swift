import Foundation
import Testing

@testable import CodansCore

/// Tab icon write-precedence, resolution and Codable migration. A tab
/// shows its selected pane's glyph unless the user picked an icon; older
/// catalog payloads must decode into a clean `.auto` / `nil` baseline.
struct TabIconTests {
  // MARK: - Write precedence

  @Test
  func userOverridesAuto() {
    let original = Tab(icon: nil, iconLock: .auto)
    let updated = original.applyingIcon("paintbrush", lock: .user)
    #expect(updated?.icon == "paintbrush")
    #expect(updated?.iconLock == .user)
  }

  @Test
  func autoCannotOverrideUser() {
    let original = Tab(icon: "paintbrush", iconLock: .user)
    let updated = original.applyingIcon("hammer", lock: .auto)
    #expect(updated == nil)
  }

  @Test
  func userNilResetsToAuto() {
    let original = Tab(icon: "paintbrush", iconLock: .user)
    let updated = original.applyingIcon(nil, lock: .user)
    #expect(updated?.icon == nil)
    #expect(updated?.iconLock == .auto)
  }

  // MARK: - Resolved icon

  @Test
  func resolvedIconPrefersUserPick() {
    let agentPane = Pane(workingDirectory: "/tmp", agentKind: .claudeCode)
    let tab = Tab(icon: "paintbrush", iconLock: .user, panes: [agentPane])
    #expect(tab.resolvedIcon(selectedPane: agentPane) == "paintbrush")
  }

  @Test
  func resolvedIconFollowsSelectedAgentPane() {
    let agentPane = Pane(workingDirectory: "/tmp", agentKind: .codex)
    let tab = Tab(panes: [agentPane])
    #expect(tab.resolvedIcon(selectedPane: agentPane) == TabIconRef.icon(for: .codex))
  }

  @Test
  func resolvedIconIgnoresAgentInUnselectedPane() {
    let agentPane = Pane(workingDirectory: "/tmp", agentKind: .claudeCode)
    let shellPane = Pane(workingDirectory: "/tmp")
    let tab = Tab(panes: [agentPane, shellPane])
    #expect(tab.resolvedIcon(selectedPane: shellPane) == TabIconRef.terminal)
  }

  @Test
  func resolvedIconIsTerminalWithoutSelectedPane() {
    #expect(Tab().resolvedIcon(selectedPane: nil) == TabIconRef.terminal)
  }

  @Test
  func resolvedIconIgnoresUnlockedStoredIcon() {
    let tab = Tab(icon: "stale-cache", iconLock: .auto)
    #expect(tab.resolvedIcon(selectedPane: nil) == TabIconRef.terminal)
  }

  @Test
  func resolvedIconIgnoresEmptyUserPick() {
    let tab = Tab(icon: "", iconLock: .user)
    #expect(tab.resolvedIcon(selectedPane: nil) == TabIconRef.terminal)
  }

  // MARK: - Codable migration

  @Test
  func decodesLegacyPayloadWithoutIconFields() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let json = """
      {
        "id": { "raw": "\(TabID().raw.uuidString)" },
        "splitTree": { "root": { "leaf": { "_0": { "raw": "\(pane.id.raw.uuidString)" } } } },
        "panes": [{
          "id": { "raw": "\(pane.id.raw.uuidString)" },
          "workingDirectory": "/tmp"
        }]
      }
      """
    let data = Data(json.utf8)
    let decoded = try JSONDecoder().decode(Tab.self, from: data)
    #expect(decoded.icon == nil)
    #expect(decoded.iconLock == .auto)
  }

  @Test
  func decodesLegacyScriptLockAsAuto() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let json = """
      {
        "id": { "raw": "\(TabID().raw.uuidString)" },
        "icon": "agent:claude-code",
        "iconLock": "script",
        "splitTree": { "root": { "leaf": { "_0": { "raw": "\(pane.id.raw.uuidString)" } } } },
        "panes": [{
          "id": { "raw": "\(pane.id.raw.uuidString)" },
          "workingDirectory": "/tmp"
        }]
      }
      """
    let decoded = try JSONDecoder().decode(Tab.self, from: Data(json.utf8))
    #expect(decoded.icon == nil)
    #expect(decoded.iconLock == .auto)
  }

  @Test
  func roundTripsLockedIcon() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(
      icon: "sparkles",
      iconLock: .user,
      splitTree: SplitTree(leaf: pane.id),
      panes: [pane]
    )
    let data = try JSONEncoder().encode(tab)
    let decoded = try JSONDecoder().decode(Tab.self, from: data)
    #expect(decoded.icon == "sparkles")
    #expect(decoded.iconLock == .user)
  }

  @Test
  func omitsIconLockKeyWhenAuto() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let data = try JSONEncoder().encode(tab)
    let body = try #require(String(bytes: data, encoding: .utf8))
    #expect(!body.contains("\"iconLock\""))
    #expect(!body.contains("\"icon\""))
  }
}
