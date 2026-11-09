import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentsViewDisplayModeToggleTests {
  @Test
  func normalOffersCompact() {
    let toggle = AgentsViewDisplayModeToggle(current: .normal)
    #expect(toggle.target == .compact)
    #expect(toggle.systemImage == "rectangle.compress.vertical")
    #expect(toggle.label == "Switch to Compact")
  }

  @Test
  func compactOffersNormal() {
    let toggle = AgentsViewDisplayModeToggle(current: .compact)
    #expect(toggle.target == .normal)
    #expect(toggle.systemImage == "rectangle.expand.vertical")
    #expect(toggle.label == "Switch to Normal")
  }

  @Test
  func toggleFlipsAndPersistsTheGlobalSetting() throws {
    let url = FileManager.default.temporaryDirectory.appending(
      component: "agents-view-display-mode-\(UUID().uuidString).json"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SettingsStore(fileURL: url)
    #expect(store.settings.general.agentsViewDisplayMode == .normal)

    AgentsViewDisplayModeToggle.apply(to: store)
    #expect(store.settings.general.agentsViewDisplayMode == .compact)
    try store.saveNow()
    #expect(SettingsStore(fileURL: url).settings.general.agentsViewDisplayMode == .compact)

    AgentsViewDisplayModeToggle.apply(to: store)
    #expect(store.settings.general.agentsViewDisplayMode == .normal)
    try store.saveNow()
    #expect(SettingsStore(fileURL: url).settings.general.agentsViewDisplayMode == .normal)
  }
}
