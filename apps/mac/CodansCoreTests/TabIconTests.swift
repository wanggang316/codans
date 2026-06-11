import Foundation
import Testing

@testable import CodansCore

/// Tab icon write-precedence and Codable migration. The `.auto` ≤
/// `.script` ≤ `.user` ordering is load-bearing for write paths; older
/// catalog payloads with no icon fields must decode into a clean
/// `.auto` / `nil` baseline.
struct TabIconTests {
  // MARK: - Write precedence

  @Test
  func userOverridesScript() {
    let original = Tab(icon: "hammer", iconLock: .script)
    let updated = original.applyingIcon("paintbrush", lock: .user)
    #expect(updated?.icon == "paintbrush")
    #expect(updated?.iconLock == .user)
  }

  @Test
  func scriptCanOverrideAuto() {
    let original = Tab(icon: "terminal", iconLock: .auto)
    let updated = original.applyingIcon("hammer", lock: .script)
    #expect(updated?.icon == "hammer")
    #expect(updated?.iconLock == .script)
  }

  @Test
  func scriptCannotOverrideUser() {
    let original = Tab(icon: "paintbrush", iconLock: .user)
    let updated = original.applyingIcon("hammer", lock: .script)
    #expect(updated == nil)
  }

  @Test
  func autoCannotOverrideScript() {
    let original = Tab(icon: "hammer", iconLock: .script)
    let updated = original.applyingIcon("terminal", lock: .auto)
    #expect(updated == nil)
  }

  @Test
  func sameLockAlwaysUpdates() {
    let original = Tab(icon: "hammer", iconLock: .script)
    let updated = original.applyingIcon("wrench", lock: .script)
    #expect(updated?.icon == "wrench")
    #expect(updated?.iconLock == .script)
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
  func resolvedIconPrefersLockedOverFallback() {
    let tab = Tab(icon: "paintbrush", iconLock: .user)
    #expect(tab.resolvedIcon(autoFallback: "terminal") == "paintbrush")
  }

  @Test
  func resolvedIconFallsBackForAutoLock() {
    let tab = Tab(icon: "stale-cache", iconLock: .auto)
    #expect(tab.resolvedIcon(autoFallback: "terminal") == "terminal")
  }

  @Test
  func resolvedIconReturnsFallbackWhenIconEmpty() {
    let tab = Tab(icon: "", iconLock: .user)
    #expect(tab.resolvedIcon(autoFallback: "terminal") == "terminal")
  }

  // MARK: - Codable migration

  @Test
  func decodesLegacyPayloadWithoutIconFields() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let json = """
      {
        "id": "\(TabID().raw.uuidString)",
        "splitTree": { "root": { "leaf": "\(pane.id.raw.uuidString)" } },
        "panes": [{
          "id": "\(pane.id.raw.uuidString)",
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
    let body = String(decoding: data, as: UTF8.self)
    #expect(!body.contains("\"iconLock\""))
    #expect(!body.contains("\"icon\""))
  }
}
