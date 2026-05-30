import Foundation
import Testing

@testable import TouchCodeCore

/// Exercises `Catalog.init(from:)` / `Catalog.encode(to:)` for the v3
/// schema (Tags + flat Projects + activeTagFilter). The decoder rejects
/// any pre-v3 payload as `unsupportedVersion`.
struct CatalogCodableTests {
  @Test
  func emptyCatalogRoundTrip() throws {
    let catalog = Catalog()
    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
    #expect(decoded.version == Catalog.currentVersion)
    #expect(decoded.activeTagFilter == .all)
  }

  @Test
  func populatedCatalogRoundTrip() throws {
    let pane = Pane(workingDirectory: "/tmp")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main", path: "/repo", branch: "main", tabs: [tab], selectedTabID: tab.id
    )
    let tag = Tag(name: "client-acme", color: .blue)
    let project = Project(
      name: "repo",
      rootPath: "/repo",
      gitRoot: "/repo",
      worktrees: [worktree],
      selectedWorktreeID: worktree.id,
      tagIDs: [tag.id]
    )
    let catalog = Catalog(
      projects: [project],
      tags: [tag],
      activeTagFilter: .tags([tag.id])
    )

    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
  }

  @Test
  func decodingRejectsUnknownVersion() throws {
    let payload = Data(#"{"version": 99, "projects": [], "tags": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(99)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  @Test
  func decodingTolerantOfMissingOptionalFields() throws {
    let payload = Data(#"{"version": 3}"#.utf8)
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.projects.isEmpty)
    #expect(catalog.tags.isEmpty)
    #expect(catalog.activeTagFilter == .all)
  }

  @Test
  func encodeOmitsActiveTagFilterWhenAll() throws {
    // Symmetric with isPinned/isExpanded: omit the key
    // when the value is the decode-time default. Pre-tag catalogs decode
    // to `.all` so writes back stay byte-identical when the filter is
    // unset.
    let catalog = Catalog()
    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["activeTagFilter"] == nil)
  }

  @Test
  func encodeIncludesActiveTagFilterWhenNonDefault() throws {
    let tag = Tag(name: "urgent", color: .red)
    let catalog = Catalog(tags: [tag], activeTagFilter: .tags([tag.id]))
    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["activeTagFilter"] != nil)
  }

  // MARK: - Pre-v3 catalogs are rejected outright

  @Test
  func decodingV2CatalogRejectsAsUnsupportedVersion() throws {
    // No backward-compat: the decoder accepts v3 only. v2 (and earlier)
    // catalogs surface as `unsupportedVersion` so the app fails loud
    // instead of silently dropping the user's data.
    let payload = Data(#"{"version": 2, "spaces": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(2)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  @Test
  func decodingV1CatalogRejectsAsUnsupportedVersion() throws {
    let payload = Data(#"{"version": 1, "spaces": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.unsupportedVersion(1)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  // MARK: - Worktree default-omission round-trips

  @Test
  func encodeOmitsArchivedAndIsPinnedWhenFalse() throws {
    let worktree = Worktree(name: "w", path: "/w")
    let project = Project(name: "p", rootPath: "/p", gitRoot: "/p", worktrees: [worktree])
    let catalog = Catalog(projects: [project])

    let data = try JSONEncoder().encode(catalog)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let projects = try #require(root["projects"] as? [[String: Any]])
    let firstProject = try #require(projects.first)
    let worktrees = try #require(firstProject["worktrees"] as? [[String: Any]])
    let firstWorktree = try #require(worktrees.first)
    #expect(firstWorktree["archived"] == nil)
    #expect(firstWorktree["isPinned"] == nil)

    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded == catalog)
  }

  // MARK: - Tab invariants

  @Test
  func tabInvariantsHoldForSeededTab() throws {
    let a = Pane(workingDirectory: "/a")
    let b = Pane(workingDirectory: "/b")
    let tree = try SplitTree(leaf: a.id).inserting(b.id, at: a.id, direction: .right)
    let tab = Tab(splitTree: tree, panes: [a, b])
    try tab.validateInvariants()
  }

  @Test
  func tabInvariantsFailWhenPanesDriftFromTree() throws {
    let a = Pane(workingDirectory: "/a")
    let b = Pane(workingDirectory: "/b")
    let extraPane = Pane(workingDirectory: "/c")
    let tree = try SplitTree(leaf: a.id).inserting(b.id, at: a.id, direction: .right)
    let badTab = Tab(splitTree: tree, panes: [a, b, extraPane])
    #expect(throws: Tab.InvariantError.self) {
      try badTab.validateInvariants()
    }
  }

  @Test
  func tabInvariantsFailOnDuplicatePaneIDs() throws {
    let a = Pane(workingDirectory: "/a")
    let tab = Tab(splitTree: SplitTree(leaf: a.id), panes: [a, a])
    #expect(throws: Tab.InvariantError.duplicatePaneIDs) {
      try tab.validateInvariants()
    }
  }

}
