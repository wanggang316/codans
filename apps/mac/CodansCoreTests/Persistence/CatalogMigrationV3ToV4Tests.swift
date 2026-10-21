import Foundation
import Testing

@testable import CodansCore

/// `CatalogMigrationV3ToV4.migrate(v3:)` against hand-written v3 documents:
/// the Pane / Tab / Content structure it builds, session identity carried
/// into `ContentID`, chip attribute placement, selection and focus,
/// consistency of the result, and the whole-document refusal of an
/// unreadable record.
struct CatalogMigrationV3ToV4Tests {
  // MARK: - v3 fixtures

  private static func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  private static func id(_ n: Int) -> String { #"{ "raw": "\#(uuid(n))" }"# }

  private static func session(_ n: Int, directory: String = "/repo", extra: String = "") -> String {
    #"{ "id": \#(id(n)), "workingDirectory": "\#(directory)"\#(extra) }"#
  }

  private static func leaf(_ n: Int) -> String { #"{ "leaf": { "_0": \#(id(n)) } }"# }

  private static func split(_ direction: String, _ ratio: Double, _ left: String, _ right: String) -> String {
    #"{ "split": { "_0": { "direction": "\#(direction)", "ratio": \#(ratio), "left": \#(left), "right": \#(right) } } }"#
  }

  private static func tree(_ root: String?, zoomed: Int? = nil) -> String {
    let rootField = root.map { #""root": \#($0)"# } ?? ""
    let zoomedField = zoomed.map { #", "zoomed": \#(id($0))"# } ?? ""
    return "{ \(rootField)\(zoomedField) }"
  }

  private static func formerTab(_ n: Int, tree: String, sessions: [String], attributes: String = "") -> String {
    #"{ "id": \#(id(n)), "splitTree": \#(tree), "panes": [\#(sessions.joined(separator: ", "))]\#(attributes) }"#
  }

  private static func singleSessionTab(_ n: Int, session: Int, attributes: String = "") -> String {
    formerTab(n, tree: tree(leaf(session)), sessions: [Self.session(session)], attributes: attributes)
  }

  private static func worktree(_ n: Int, tabs: [String], selected: Int? = nil, extra: String = "") -> String {
    let selection = selected.map { #", "selectedTabID": \#(id($0))"# } ?? ""
    return
      #"{ "id": \#(id(n)), "name": "w\#(n)", "path": "/repo/w\#(n)", "tabs": [\#(tabs.joined(separator: ", "))]\#(selection)\#(extra) }"#
  }

  private static func catalog(worktrees: [String], projectExtra: String = "", catalogExtra: String = "") -> Data {
    let project =
      #"{ "id": \#(id(30)), "rootPath": "/repo", "worktrees": [\#(worktrees.joined(separator: ", "))]\#(projectExtra) }"#
    return Data(#"{ "version": 3, "projects": [\#(project)]\#(catalogExtra) }"#.utf8)
  }

  private static let attributes =
    #", "name": "dev", "cachedDisplayTitle": "npm run dev", "color": "blue", "icon": "hammer", "iconLock": "user""#

  private func migrateSingleWorktree(_ data: Data) throws -> Worktree {
    let catalog = try CatalogMigrationV3ToV4.migrate(v3: data)
    return try #require(catalog.projects.first?.worktrees.first)
  }

  private func content(_ n: Int) -> ContentID { ContentID(raw: Self.uuid(n)) }

  // MARK: - Structure

  @Test
  func singleFormerTabBecomesOnePaneWithOneTab() throws {
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [
        Self.worktree(20, tabs: [Self.singleSessionTab(1, session: 101, attributes: Self.attributes)], selected: 1)
      ]))

    try worktree.validateInvariants()
    #expect(worktree.panes.count == 1)
    let pane = try #require(worktree.panes.first)
    #expect(worktree.splitTree == SplitTree(leaf: pane.id))
    #expect(worktree.focusedPaneID == pane.id)
    #expect(pane.tabs.count == 1)
    let tab = try #require(pane.tabs.first)
    #expect(pane.selectedTabID == tab.id)
    #expect(tab.id != TabID(raw: Self.uuid(1)))
    #expect(tab.content.id == content(101))
    #expect(tab.content.terminal?.workingDirectory == "/repo")
    #expect(tab.name == "dev")
    #expect(tab.cachedDisplayTitle == "npm run dev")
    #expect(tab.color == .blue)
    #expect(tab.icon == "hammer")
    #expect(tab.iconLock == .user)
  }

  @Test
  func terminalStateOfASessionCarriesOver() throws {
    let extra =
      #", "labels": ["b", "a"], "agentKind": "claude-code", "agentSessionID": "s-1", "runScriptID": "\#(Self.uuid(900))""#
    let tab = Self.formerTab(
      1, tree: Self.tree(Self.leaf(101)), sessions: [Self.session(101, directory: "/x", extra: extra)])
    let worktree = try migrateSingleWorktree(Self.catalog(worktrees: [Self.worktree(20, tabs: [tab])]))

    let terminal = try #require(worktree.panes.first?.tabs.first?.content.terminal)
    #expect(terminal.workingDirectory == "/x")
    #expect(terminal.labels == ["a", "b"])
    #expect(terminal.agentKind == .claudeCode)
    #expect(terminal.agentSessionID == "s-1")
    #expect(terminal.runScriptID == Self.uuid(900))
    #expect(terminal.initialCommand == nil)
  }

  @Test
  func otherFormerTabsStackIntoTheFocusedPaneInOrder() throws {
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [
        Self.worktree(
          20,
          tabs: [
            Self.singleSessionTab(1, session: 101, attributes: #", "name": "first""#),
            Self.singleSessionTab(2, session: 102, attributes: #", "name": "second""#),
            Self.singleSessionTab(3, session: 103, attributes: #", "color": "red""#),
          ],
          selected: 2)
      ]))

    try worktree.validateInvariants()
    #expect(worktree.panes.count == 1)
    let pane = try #require(worktree.panes.first)
    #expect(pane.contentIDs == [content(102), content(101), content(103)])
    #expect(pane.tabs.map(\.name) == ["second", "first", nil])
    #expect(pane.tabs.map(\.color) == [nil, nil, .red])
    #expect(pane.selectedTabID == pane.tabs[0].id)
    #expect(Set(pane.tabIDs).isDisjoint(with: [1, 2, 3].map { TabID(raw: Self.uuid($0)) }))
  }

  @Test
  func selectedSplitFormerTabBecomesTheLayoutWithRatiosKept() throws {
    // A | (B / C): horizontal at 0.3, then vertical at 0.6.
    let layoutTree = Self.tree(
      Self.split("horizontal", 0.3, Self.leaf(101), Self.split("vertical", 0.6, Self.leaf(102), Self.leaf(103))))
    let selected = Self.formerTab(
      1, tree: layoutTree,
      sessions: [
        Self.session(101, directory: "/a"), Self.session(102, directory: "/b"), Self.session(103, directory: "/c"),
      ],
      attributes: Self.attributes)
    // Another two-leaf former Tab fans into the focused Pane in leaf order.
    let other = Self.formerTab(
      2, tree: Self.tree(Self.split("vertical", 0.5, Self.leaf(105), Self.leaf(104))),
      sessions: [Self.session(104), Self.session(105)], attributes: #", "name": "other""#)
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [Self.worktree(20, tabs: [other, selected], selected: 1)]))

    try worktree.validateInvariants()
    #expect(worktree.panes.count == 3)
    let paneA = try #require(worktree.pane(forContent: content(101)))
    let paneB = try #require(worktree.pane(forContent: content(102)))
    let paneC = try #require(worktree.pane(forContent: content(103)))
    let expectedTree = SplitTree<PaneID>(
      root: .split(
        .init(
          direction: .horizontal, ratio: 0.3, left: .leaf(paneA.id),
          right: .split(.init(direction: .vertical, ratio: 0.6, left: .leaf(paneB.id), right: .leaf(paneC.id))))))
    #expect(worktree.splitTree == expectedTree)
    #expect(worktree.splitTree.leaves() == [paneA.id, paneB.id, paneC.id])
    #expect(worktree.focusedPaneID == paneA.id)
    #expect(paneA.contentIDs == [content(101), content(105), content(104)])
    #expect(paneB.contentIDs == [content(102)])
    #expect(paneC.contentIDs == [content(103)])
    #expect(paneA.selectedTabID == paneA.tabs[0].id)
    #expect(paneA.tabs[0].name == "dev")
    #expect(paneA.tabs[1].name == "other")
    #expect(paneA.tabs[2].name == nil)
    #expect(paneB.tabs[0].name == nil)
    #expect(paneA.tabs.map(\.content.terminal?.workingDirectory) == ["/a", "/repo", "/repo"])
  }

  @Test
  func zoomedLeafPicksTheFocusedPaneAndTheZoomIsDropped() throws {
    let selected = Self.formerTab(
      1, tree: Self.tree(Self.split("horizontal", 0.5, Self.leaf(101), Self.leaf(102)), zoomed: 102),
      sessions: [Self.session(101), Self.session(102)])
    let other = Self.singleSessionTab(2, session: 103)
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [Self.worktree(20, tabs: [selected, other], selected: 1)]))

    try worktree.validateInvariants()
    let paneB = try #require(worktree.pane(forContent: content(102)))
    #expect(worktree.focusedPaneID == paneB.id)
    #expect(worktree.splitTree.zoomed == nil)
    #expect(paneB.contentIDs == [content(102), content(103)])
    #expect(worktree.pane(forContent: content(101))?.contentIDs == [content(101)])
  }

  @Test
  func emptyFormerTabIsDroppedEvenWhenSelected() throws {
    let empty = Self.formerTab(1, tree: Self.tree(nil), sessions: [], attributes: Self.attributes)
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [
        Self.worktree(
          20, tabs: [empty, Self.singleSessionTab(2, session: 102), Self.singleSessionTab(3, session: 103)],
          selected: 1)
      ]))

    try worktree.validateInvariants()
    #expect(worktree.panes.count == 1)
    let pane = try #require(worktree.panes.first)
    #expect(pane.contentIDs == [content(102), content(103)])
    #expect(pane.tabs.allSatisfy { $0.name == nil && $0.color == nil })
  }

  @Test
  func nilSelectionFallsBackToTheFirstFormerTab() throws {
    let first = Self.formerTab(
      1, tree: Self.tree(Self.split("vertical", 0.5, Self.leaf(101), Self.leaf(102))),
      sessions: [Self.session(101), Self.session(102)])
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [Self.worktree(20, tabs: [first, Self.singleSessionTab(2, session: 103)])]))

    try worktree.validateInvariants()
    #expect(worktree.panes.count == 2)
    #expect(worktree.splitTree.isSplit)
    let paneA = try #require(worktree.pane(forContent: content(101)))
    #expect(worktree.focusedPaneID == paneA.id)
    #expect(paneA.contentIDs == [content(101), content(103)])
  }

  @Test
  func danglingSelectionFallsBackToTheFirstFormerTab() throws {
    let worktree = try migrateSingleWorktree(
      Self.catalog(worktrees: [
        Self.worktree(
          20, tabs: [Self.singleSessionTab(1, session: 101), Self.singleSessionTab(2, session: 102)], selected: 9)
      ]))
    #expect(worktree.panes.first?.contentIDs == [content(101), content(102)])
  }

  @Test
  func worktreeWithoutSessionsHasNoPanesAndNoFocus() throws {
    let catalog = try CatalogMigrationV3ToV4.migrate(
      v3: Self.catalog(worktrees: [
        Self.worktree(20, tabs: []),
        Self.worktree(21, tabs: [Self.formerTab(1, tree: Self.tree(nil), sessions: [])], selected: 1),
      ]))

    for worktree in catalog.projects[0].worktrees {
      try worktree.validateInvariants()
      #expect(worktree.panes.isEmpty)
      #expect(worktree.splitTree.isEmpty)
      #expect(worktree.focusedPaneID == nil)
    }
  }

  @Test
  func sessionRecordsOutsideTheTreeAreKept() throws {
    // A drifted v3 tree references only one of the two records; the other
    // still becomes a Tab instead of vanishing.
    let drifted = Self.formerTab(1, tree: Self.tree(Self.leaf(101)), sessions: [Self.session(101), Self.session(102)])
    let worktree = try migrateSingleWorktree(Self.catalog(worktrees: [Self.worktree(20, tabs: [drifted])]))

    try worktree.validateInvariants()
    #expect(worktree.panes.count == 1)
    #expect(worktree.panes[0].contentIDs == [content(101), content(102)])
  }

  // MARK: - Pass-through

  @Test
  func projectAndWorktreeFieldsPassThroughUnchanged() throws {
    let archived = Self.worktree(
      21, tabs: [Self.singleSessionTab(2, session: 102)],
      extra:
        #", "branch": "fix", "headSHA": "abc123", "archived": true, "isPinned": true, "isNew": true, "sourceGitRoot": "/other""#,
    )
    let data = Self.catalog(
      worktrees: [Self.worktree(20, tabs: [Self.singleSessionTab(1, session: 101)]), archived],
      projectExtra:
        #", "displayName": "Repo", "gitRoot": "/repo", "selectedWorktreeID": \#(Self.id(21)), "isExpanded": false, "tagIDs": [\#(Self.id(40))], "manualOrder": 3"#,
      catalogExtra:
        #", "tags": [{ "id": \#(Self.id(40)), "name": "client", "color": "blue" }], "activeTagFilter": { "kind": "tags", "tagIDs": [\#(Self.id(40))] },"projectSortMode": "manual", "selectedProjectID": \#(Self.id(30))"#,
    )

    let catalog = try CatalogMigrationV3ToV4.migrate(v3: data)

    #expect(catalog.version == 4)
    #expect(catalog.tags.map(\.id) == [TagID(raw: Self.uuid(40))])
    #expect(catalog.activeTagFilter == .tags([TagID(raw: Self.uuid(40))]))
    #expect(catalog.projectSortMode == .manual)
    #expect(catalog.selectedProjectID == ProjectID(raw: Self.uuid(30)))
    let project = try #require(catalog.projects.first)
    #expect(project.id == ProjectID(raw: Self.uuid(30)))
    #expect(project.displayName == "Repo")
    #expect(project.gitRoot == "/repo")
    #expect(project.selectedWorktreeID == WorktreeID(raw: Self.uuid(21)))
    #expect(project.isExpanded == false)
    #expect(project.tagIDs == [TagID(raw: Self.uuid(40))])
    #expect(project.manualOrder == 3)
    #expect(project.worktrees.map(\.id) == [WorktreeID(raw: Self.uuid(20)), WorktreeID(raw: Self.uuid(21))])
    let second = project.worktrees[1]
    #expect(second.name == "w21")
    #expect(second.path == "/repo/w21")
    #expect(second.branch == "fix")
    #expect(second.headSHA == "abc123")
    #expect(second.archived)
    #expect(second.isPinned)
    #expect(second.isNew)
    #expect(second.sourceGitRoot == "/other")
    #expect(second.contentIDs == [content(102)])
    #expect(project.worktrees[0].contentIDs == [content(101)])
  }

  @Test
  func migratedCatalogReEncodesAsV4AndDecodesBackEqual() throws {
    let selected = Self.formerTab(
      1, tree: Self.tree(Self.split("horizontal", 0.25, Self.leaf(101), Self.leaf(102)), zoomed: 101),
      sessions: [Self.session(101), Self.session(102)], attributes: Self.attributes)
    let catalog = try CatalogMigrationV3ToV4.migrate(
      v3: Self.catalog(worktrees: [
        Self.worktree(20, tabs: [selected, Self.singleSessionTab(2, session: 103)], selected: 1)
      ]))

    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["version"] as? Int == 4)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
    try decoded.validateLayouts()
  }

  // MARK: - Refusal

  @Test
  func anUnreadableSessionRecordFailsTheWholeMigration() throws {
    let broken = Self.formerTab(
      1, tree: Self.tree(Self.leaf(101)), sessions: [#"{ "id": \#(Self.id(101)) }"#])
    let data = Self.catalog(worktrees: [
      Self.worktree(20, tabs: [Self.singleSessionTab(2, session: 102)]),
      Self.worktree(21, tabs: [broken]),
    ])
    #expect(throws: DecodingError.self) {
      _ = try CatalogMigrationV3ToV4.migrate(v3: data)
    }
  }

  @Test
  func anUnreadableFormerTabFailsTheWholeMigration() throws {
    let noTree = #"{ "id": \#(Self.id(1)), "panes": [\#(Self.session(101))] }"#
    let data = Self.catalog(worktrees: [Self.worktree(20, tabs: [noTree])])
    #expect(throws: DecodingError.self) {
      _ = try CatalogMigrationV3ToV4.migrate(v3: data)
    }
  }

  @Test
  func aSessionListedInTwoFormerTabsIsRejectedAsInconsistent() throws {
    let data = Self.catalog(worktrees: [
      Self.worktree(20, tabs: [Self.singleSessionTab(1, session: 101), Self.singleSessionTab(2, session: 101)])
    ])
    #expect(throws: Catalog.LayoutIssue.inconsistentWorktree(WorktreeID(raw: Self.uuid(20)), .duplicateContentIDs)) {
      _ = try CatalogMigrationV3ToV4.migrate(v3: data)
    }
  }

  @Test
  func aDocumentOfAnotherVersionIsRefused() throws {
    let data = Data(#"{ "version": 4, "projects": [] }"#.utf8)
    #expect(throws: CatalogMigrationV3ToV4.Failure.notVersion3(4)) {
      _ = try CatalogMigrationV3ToV4.migrate(v3: data)
    }
  }
}
