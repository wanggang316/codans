import Foundation
import Testing

@testable import CodansCore

/// Tab Codable shape. Catalogs written by older builds carry per-tab
/// `color`, `icon` and `iconLock` keys; they must still decode, and the
/// next save must drop them.
struct TabCodableTests {
  @Test
  func decodesAndDropsRetiredKeys() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let json = """
      {
        "id": { "raw": "\(TabID().raw.uuidString)" },
        "name": "dev",
        "color": "purple",
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
    #expect(decoded.name == "dev")
    #expect(decoded.panes.map(\.id) == [pane.id])

    let body = try #require(String(bytes: JSONEncoder().encode(decoded), encoding: .utf8))
    #expect(!body.contains("\"color\""))
    #expect(!body.contains("\"icon\""))
    #expect(!body.contains("\"iconLock\""))
  }

  @Test
  func omitsUnsetOptionalKeys() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let body = try #require(String(bytes: JSONEncoder().encode(tab), encoding: .utf8))
    #expect(!body.contains("\"name\""))
    #expect(!body.contains("\"cachedDisplayTitle\""))
    #expect(!body.contains("\"cachedDisplayTitlePaneID\""))
  }

  @Test
  func cachedTitlePaneRoundTrips() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(
      cachedDisplayTitle: "vim", cachedDisplayTitlePaneID: pane.id,
      splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
    #expect(decoded.cachedDisplayTitle == "vim")
    #expect(decoded.cachedDisplayTitlePaneID == pane.id)
  }
}
