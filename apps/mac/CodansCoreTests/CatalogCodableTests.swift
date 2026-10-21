import Foundation
import Testing

@testable import CodansCore

/// Exercises `Catalog.init(from:)` / `Catalog.encode(to:)` for the v4
/// schema. The decoder reads the current version only and names why it
/// refused any other: pre-v3 as `unsupportedVersion`, v3 as
/// `needsMigration`, above v4 as `newerVersion`.
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
    let pane = Pane(tabs: [Tab(content: .terminal(workingDirectory: "/tmp"))])
    let worktree = Worktree(
      name: "main", path: "/repo", branch: "main", splitTree: SplitTree(leaf: pane.id), panes: [pane],
      focusedPaneID: pane.id
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
  func decodingNewerVersionIsDistinctFromUnsupported() throws {
    let payload = Data(#"{"version": 99, "projects": [], "tags": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.newerVersion(99)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  @Test
  func decodingV3CatalogAsksForMigration() throws {
    let payload = Data(#"{"version": 3, "projects": []}"#.utf8)
    #expect(throws: Catalog.DecodingIssue.needsMigration(3)) {
      _ = try JSONDecoder().decode(Catalog.self, from: payload)
    }
  }

  @Test
  func peekVersionReadsTheVersionAlone() throws {
    // The rest of the document is not this build's shape on purpose.
    let payload = Data(#"{"version": 7, "projects": "not an array"}"#.utf8)
    #expect(try Catalog.peekVersion(in: payload) == 7)
    #expect(throws: DecodingError.self) {
      _ = try Catalog.peekVersion(in: Data(#"{"projects": []}"#.utf8))
    }
  }

  @Test
  func decodingTolerantOfMissingOptionalFields() throws {
    let payload = Data(#"{"version": 4}"#.utf8)
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
    // v2 (and earlier) catalogs have no migration path: they surface as
    // `unsupportedVersion` so the app fails loud instead of silently
    // dropping the user's data.
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

  // MARK: - isNew round-trips

  @Test
  func isNewTrueRoundTrips() throws {
    // Encode a worktree with isNew == true; decode must preserve the flag.
    let worktree = Worktree(name: "w", path: "/w", isNew: true)
    let data = try JSONEncoder().encode(worktree)
    let decoded = try JSONDecoder().decode(Worktree.self, from: data)
    #expect(decoded.isNew == true)
    #expect(decoded == worktree)
  }

  @Test
  func isNewFalseOmitsKeyFromJSON() throws {
    // Encode a worktree with isNew == false; the JSON must not contain the key
    // so pre-existing catalogs round-trip identically.
    let worktree = Worktree(name: "w", path: "/w", isNew: false)
    let data = try JSONEncoder().encode(worktree)
    let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(dict["isNew"] == nil)
  }

  @Test
  func isNewAbsentInJSONDecodesToFalse() throws {
    // Simulate a pre-isNew catalog entry: strip the key from the encoded dict,
    // then verify decoding falls back to false (backward-compat).
    let worktree = Worktree(name: "w", path: "/w", isNew: true)
    let encoded = try JSONEncoder().encode(worktree)
    var dict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    dict.removeValue(forKey: "isNew")
    let stripped = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(Worktree.self, from: stripped)
    #expect(decoded.isNew == false)
  }

  // MARK: - runScriptID round-trips

  @Test
  func runScriptIDRoundTrips() throws {
    // The run-script association must survive a relaunch, so unlike the
    // agent binding this field persists.
    let scriptID = UUID()
    let state = TerminalContentState(workingDirectory: "/tmp", runScriptID: scriptID)
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: data)
    #expect(decoded.runScriptID == scriptID)
  }

  @Test
  func runScriptIDNilOmitsKeyFromJSON() throws {
    let state = TerminalContentState(workingDirectory: "/tmp")
    let data = try JSONEncoder().encode(state)
    let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(dict["runScriptID"] == nil)

    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: data)
    #expect(decoded.runScriptID == nil)
  }
}
