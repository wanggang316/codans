import Foundation
import Testing

@testable import CodansCore

/// Wire shape of the Pane layout: kind-keyed content, omit-when-default
/// keys, repair of dangling selection / focus, element-wise Tab decode
/// with a loss count, and a byte-identical round trip of a canonical
/// catalog.
struct PaneLayoutCodableTests {
  // MARK: - Fixtures

  private static func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  private func terminalTab(_ n: Int, directory: String) -> Tab {
    Tab(
      id: TabID(raw: Self.uuid(n)),
      content: ContentSnapshot(
        id: ContentID(raw: Self.uuid(n + 100)),
        state: .terminal(TerminalContentState(workingDirectory: directory))))
  }

  /// Two Panes side by side; the left one stacks two Tabs. Every field a
  /// user can set is set on one Tab so the fixture covers each key once.
  private func canonicalCatalog() throws -> Catalog {
    var named = terminalTab(1, directory: "/repo")
    named.name = "dev server"
    named.cachedDisplayTitle = "npm run dev"
    named.color = .blue
    named.icon = "hammer"
    named.iconLock = .user
    named.content.terminal?.labels = ["agent", "server"]
    named.content.terminal?.agentKind = .claudeCode
    named.content.terminal?.agentSessionID = "session-1"
    named.content.terminal?.runScriptID = Self.uuid(900)
    named.content.terminal?.commandQueue = [
      QueuedCommand(
        id: Self.uuid(901), text: "make test", timing: .afterCurrentTask,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    ]
    let plain = terminalTab(2, directory: "/repo/sub")
    let right = terminalTab(3, directory: "/repo")
    let leftPane = Pane(id: PaneID(raw: Self.uuid(10)), tabs: [named, plain], selectedTabID: plain.id)
    let rightPane = Pane(id: PaneID(raw: Self.uuid(11)), tabs: [right])
    let tree = try SplitTree(leaf: leftPane.id).inserting(rightPane.id, at: leftPane.id, direction: .right)
    let worktree = Worktree(
      id: WorktreeID(raw: Self.uuid(20)), name: "main", path: "/repo", branch: "main",
      splitTree: tree, panes: [leftPane, rightPane], focusedPaneID: rightPane.id)
    let project = Project(
      id: ProjectID(raw: Self.uuid(30)), name: "repo", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id)
    return Catalog(projects: [project])
  }

  private static func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func stableEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private func decode<T: Decodable>(_ type: T.Type, _ json: String, loss: CatalogDecodeLoss? = nil) throws -> T {
    let decoder = JSONDecoder()
    loss?.attach(to: decoder)
    return try decoder.decode(type, from: Data(json.utf8))
  }

  // MARK: - Round trip

  @Test
  func canonicalCatalogRoundTripsByteIdentically() throws {
    let catalog = try canonicalCatalog()
    for worktree in catalog.projects.flatMap(\.worktrees) {
      try worktree.validateInvariants()
    }
    let encoder = Self.stableEncoder()
    let first = try encoder.encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: first)
    #expect(decoded == catalog)
    #expect(decoded.version == Catalog.currentVersion)
    let second = try encoder.encode(decoded)
    #expect(first == second)
  }

  // MARK: - Kind-keyed content

  @Test
  func tabEncodesContentUnderAKindKey() throws {
    let tab = Tab(content: .terminal(workingDirectory: "/repo"))
    let root = try Self.json(try JSONEncoder().encode(tab))
    let content = try #require(root["content"] as? [String: Any])
    #expect(content["id"] != nil)
    let state = try #require(content["state"] as? [String: Any])
    #expect(state["kind"] as? String == "terminal")
    let terminal = try #require(state["terminal"] as? [String: Any])
    #expect(terminal["workingDirectory"] as? String == "/repo")
    #expect(Set(state.keys) == ["kind", "terminal"])
  }

  @Test
  func unknownContentKindFailsThatTab() {
    let json = """
      { "id": { "raw": "\(Self.uuid(1))" },
        "content": { "id": { "raw": "\(Self.uuid(2))" },
                     "state": { "kind": "browser", "browser": { "url": "https://example.com" } } } }
      """
    #expect(throws: DecodingError.self) { _ = try decode(Tab.self, json) }
  }

  // MARK: - Omit-when-default

  @Test
  func unsetTabOmitsEveryDefaultKey() throws {
    let tab = Tab(content: .terminal(workingDirectory: "/repo"))
    let root = try Self.json(try JSONEncoder().encode(tab))
    #expect(Set(root.keys) == ["id", "content"])
    let terminal = try #require(
      ((root["content"] as? [String: Any])?["state"] as? [String: Any])?["terminal"] as? [String: Any])
    #expect(Set(terminal.keys) == ["workingDirectory"])
  }

  @Test
  func initialCommandIsNeverEncoded() throws {
    let tab = Tab(content: .terminal(workingDirectory: "/repo", initialCommand: "claude --resume"))
    let data = try JSONEncoder().encode(tab)
    let body = try #require(String(data: data, encoding: .utf8))
    #expect(!body.contains("initialCommand"))
    #expect(!body.contains("claude --resume"))
    let decoded = try JSONDecoder().decode(Tab.self, from: data)
    #expect(decoded.content.terminal?.initialCommand == nil)
  }

  @Test
  func worktreeWithoutPanesOmitsLayoutKeys() throws {
    let worktree = Worktree(name: "w", path: "/w")
    let root = try Self.json(try JSONEncoder().encode(worktree))
    #expect(root["splitTree"] == nil)
    #expect(root["panes"] == nil)
    #expect(root["focusedPaneID"] == nil)
    let decoded = try JSONDecoder().decode(Worktree.self, from: try JSONEncoder().encode(worktree))
    #expect(decoded == worktree)
    #expect(decoded.isConsistent)
  }

  // MARK: - Decode repair

  @Test
  func danglingSelectionFallsBackToTheFirstTab() throws {
    let json = """
      { "id": { "raw": "\(Self.uuid(10))" },
        "selectedTabID": { "raw": "\(Self.uuid(99))" },
        "tabs": [
          { "id": { "raw": "\(Self.uuid(1))" },
            "content": { "id": { "raw": "\(Self.uuid(101))" },
                         "state": { "kind": "terminal", "terminal": { "workingDirectory": "/a" } } } },
          { "id": { "raw": "\(Self.uuid(2))" },
            "content": { "id": { "raw": "\(Self.uuid(102))" },
                         "state": { "kind": "terminal", "terminal": { "workingDirectory": "/b" } } } }
        ] }
      """
    let pane = try decode(Pane.self, json)
    #expect(pane.selectedTabID == TabID(raw: Self.uuid(1)))
    #expect(pane.hasResolvedSelection)
  }

  @Test
  func missingSelectionFallsBackToTheFirstTab() throws {
    let json = """
      { "id": { "raw": "\(Self.uuid(10))" },
        "tabs": [
          { "id": { "raw": "\(Self.uuid(1))" },
            "content": { "id": { "raw": "\(Self.uuid(101))" },
                         "state": { "kind": "terminal", "terminal": { "workingDirectory": "/a" } } } }
        ] }
      """
    let pane = try decode(Pane.self, json)
    #expect(pane.selectedTabID == TabID(raw: Self.uuid(1)))
  }

  @Test
  func danglingFocusFallsBackToTheFirstPane() throws {
    var catalog = try canonicalCatalog()
    catalog.projects[0].worktrees[0].focusedPaneID = PaneID(raw: Self.uuid(99))
    let decoded = try JSONDecoder().decode(Catalog.self, from: try JSONEncoder().encode(catalog))
    let worktree = decoded.projects[0].worktrees[0]
    #expect(worktree.focusedPaneID == PaneID(raw: Self.uuid(10)))
    try worktree.validateInvariants()
  }

  @Test
  func missingFocusFallsBackToTheFirstPane() throws {
    var catalog = try canonicalCatalog()
    catalog.projects[0].worktrees[0].focusedPaneID = nil
    let decoded = try JSONDecoder().decode(Catalog.self, from: try JSONEncoder().encode(catalog))
    #expect(decoded.projects[0].worktrees[0].focusedPaneID == PaneID(raw: Self.uuid(10)))
  }

  @Test
  func decodeDoesNotReconcileTreeAgainstPanes() throws {
    var catalog = try canonicalCatalog()
    catalog.projects[0].worktrees[0].splitTree = SplitTree(leaf: PaneID(raw: Self.uuid(10)))
    let decoded = try JSONDecoder().decode(Catalog.self, from: try JSONEncoder().encode(catalog))
    let worktree = decoded.projects[0].worktrees[0]
    #expect(worktree.panes.count == 2)
    #expect(!worktree.isConsistent)
  }

  // MARK: - Element-wise loss

  @Test
  func anUnreadableTabIsDroppedAndCountedWhileTheOthersSurvive() throws {
    var catalog = try canonicalCatalog()
    let data = try Self.stableEncoder().encode(catalog)
    var root = try Self.json(data)
    var projects = try #require(root["projects"] as? [[String: Any]])
    var worktrees = try #require(projects[0]["worktrees"] as? [[String: Any]])
    var panes = try #require(worktrees[0]["panes"] as? [[String: Any]])
    var tabs = try #require(panes[0]["tabs"] as? [[String: Any]])
    tabs[0]["content"] = ["id": ["raw": Self.uuid(101).uuidString], "state": ["kind": "terminal"]]
    panes[0]["tabs"] = tabs
    worktrees[0]["panes"] = panes
    projects[0]["worktrees"] = worktrees
    root["projects"] = projects
    let malformed = try JSONSerialization.data(withJSONObject: root)

    let loss = CatalogDecodeLoss()
    let decoder = JSONDecoder()
    loss.attach(to: decoder)
    let decoded = try decoder.decode(Catalog.self, from: malformed)

    #expect(loss.droppedTabs == 1)
    #expect(loss.droppedPanes == 0)
    #expect(!loss.isEmpty)
    let worktree = decoded.projects[0].worktrees[0]
    try worktree.validateInvariants()
    #expect(worktree.panes.map(\.tabs.count) == [1, 1])
    #expect(worktree.panes[0].tabs[0].id == TabID(raw: Self.uuid(2)))
    #expect(worktree.panes[0].selectedTabID == TabID(raw: Self.uuid(2)))
    catalog.projects[0].worktrees[0].panes[0].tabs.removeFirst()
    #expect(decoded == catalog)
  }

  @Test
  func aPaneWhoseTabsAllDroppedLeavesWithItsLeaf() throws {
    let json = """
      { "id": { "raw": "\(Self.uuid(20))" }, "name": "w", "path": "/w",
        "splitTree": { "root": { "split": { "_0": {
          "direction": "horizontal", "ratio": 0.5,
          "left": { "leaf": { "_0": { "raw": "\(Self.uuid(10))" } } },
          "right": { "leaf": { "_0": { "raw": "\(Self.uuid(11))" } } } } } } },
        "focusedPaneID": { "raw": "\(Self.uuid(10))" },
        "panes": [
          { "id": { "raw": "\(Self.uuid(10))" }, "tabs": [ "not a tab", 42 ] },
          { "id": { "raw": "\(Self.uuid(11))" }, "tabs": [
            { "id": { "raw": "\(Self.uuid(3))" },
              "content": { "id": { "raw": "\(Self.uuid(103))" },
                           "state": { "kind": "terminal", "terminal": { "workingDirectory": "/c" } } } } ] }
        ] }
      """
    let loss = CatalogDecodeLoss()
    let worktree = try decode(Worktree.self, json, loss: loss)
    #expect(loss.droppedTabs == 2)
    #expect(loss.droppedPanes == 1)
    #expect(worktree.panes.map(\.id) == [PaneID(raw: Self.uuid(11))])
    #expect(worktree.splitTree.leaves() == [PaneID(raw: Self.uuid(11))])
    #expect(worktree.focusedPaneID == PaneID(raw: Self.uuid(11)))
    try worktree.validateInvariants()
  }

  @Test
  func lossIsTolerantWithoutACollector() throws {
    let json = """
      { "id": { "raw": "\(Self.uuid(10))" }, "tabs": [ "not a tab" ] }
      """
    let pane = try decode(Pane.self, json)
    #expect(pane.tabs.isEmpty)
  }
}
