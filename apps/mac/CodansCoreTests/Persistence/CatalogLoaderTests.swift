import Foundation
import Testing

@testable import CodansCore

/// `CatalogLoader.decode(_:)` routes on the `version` field: the current
/// version decodes tolerantly with a loss count, version 3 migrates, a
/// newer version is read-only, and anything older is refused.
struct CatalogLoaderTests {
  private static func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  private static func id(_ n: Int) -> String { #"{ "raw": "\#(uuid(n))" }"# }

  private static func tab(_ n: Int) -> String {
    #"{ "id": \#(id(n)), "content": { "id": \#(id(n + 100)), "state": { "kind": "terminal", "terminal": { "workingDirectory": "/repo" } } } }"#
  }

  private static func v4(panes: String, focused: Int?) -> Data {
    let focus = focused.map { #", "focusedPaneID": \#(id($0))"# } ?? ""
    let worktree =
      #"{ "id": \#(id(20)), "name": "w", "path": "/repo", "splitTree": { "root": { "leaf": { "_0": \#(id(10)) } } }, "panes": [\#(panes)]\#(focus) }"#
    let project = #"{ "id": \#(id(30)), "rootPath": "/repo", "worktrees": [\#(worktree)] }"#
    return Data(#"{ "version": 4, "projects": [\#(project)] }"#.utf8)
  }

  @Test
  func currentVersionDecodesWithAnEmptyLoss() throws {
    let data = Self.v4(panes: #"{ "id": \#(Self.id(10)), "tabs": [\#(Self.tab(1))] }"#, focused: 10)
    guard case .current(let catalog, let loss) = try CatalogLoader.decode(data) else {
      Issue.record("expected .current")
      return
    }
    #expect(loss.isEmpty)
    #expect(catalog.version == 4)
    #expect(catalog.projects[0].worktrees[0].contentIDs == [ContentID(raw: Self.uuid(101))])
  }

  @Test
  func currentVersionCountsAMalformedTab() throws {
    let data = Self.v4(panes: #"{ "id": \#(Self.id(10)), "tabs": [\#(Self.tab(1)), "not a tab"] }"#, focused: 10)
    guard case .current(let catalog, let loss) = try CatalogLoader.decode(data) else {
      Issue.record("expected .current")
      return
    }
    #expect(loss.droppedTabs == 1)
    #expect(loss.droppedPanes == 0)
    #expect(catalog.projects[0].worktrees[0].panes[0].tabs.count == 1)
    try catalog.validateLayouts()
  }

  @Test
  func currentVersionWithAnInconsistentLayoutIsRefused() throws {
    // Two Panes, one leaf: the tree and the Pane list disagree.
    let panes =
      #"{ "id": \#(Self.id(10)), "tabs": [\#(Self.tab(1))] }, { "id": \#(Self.id(11)), "tabs": [\#(Self.tab(2))] }"#
    #expect(throws: Catalog.LayoutIssue.self) {
      _ = try CatalogLoader.decode(Self.v4(panes: panes, focused: 10))
    }
  }

  @Test
  func version3Migrates() throws {
    let formerTab =
      #"{ "id": \#(Self.id(1)), "splitTree": { "root": { "leaf": { "_0": \#(Self.id(101)) } } }, "panes": [{ "id": \#(Self.id(101)), "workingDirectory": "/repo" }] }"#
    let worktree =
      #"{ "id": \#(Self.id(20)), "name": "w", "path": "/repo", "tabs": [\#(formerTab)], "selectedTabID": \#(Self.id(1)) }"#
    let project = #"{ "id": \#(Self.id(30)), "rootPath": "/repo", "worktrees": [\#(worktree)] }"#
    let data = Data(#"{ "version": 3, "projects": [\#(project)] }"#.utf8)

    guard case .migrated(let catalog, let fromVersion) = try CatalogLoader.decode(data) else {
      Issue.record("expected .migrated")
      return
    }
    #expect(fromVersion == 3)
    #expect(catalog.version == 4)
    let migrated = catalog.projects[0].worktrees[0]
    try migrated.validateInvariants()
    #expect(migrated.contentIDs == [ContentID(raw: Self.uuid(101))])
  }

  @Test
  func aNewerVersionIsReadOnly() throws {
    let data = Data(#"{ "version": 5, "projects": [{ "shape": "unknown" }] }"#.utf8)
    guard case .readOnly(let version) = try CatalogLoader.decode(data) else {
      Issue.record("expected .readOnly")
      return
    }
    #expect(version == 5)
    #expect(try CatalogLoader.decode(data).catalog == nil)
  }

  @Test
  func version2IsRefused() throws {
    let data = Data(#"{ "version": 2, "spaces": [] }"#.utf8)
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(2)) {
      _ = try CatalogLoader.decode(data)
    }
  }

  @Test
  func aDocumentWithoutAVersionIsADecodingError() throws {
    #expect(throws: DecodingError.self) {
      _ = try CatalogLoader.decode(Data(#"{ "projects": [] }"#.utf8))
    }
  }
}
