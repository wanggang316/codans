import Foundation
import Testing

@testable import CodansCore

/// Project order (ADR 0001): drop resolution by `ProjectID`, the move applied
/// to the full list, and the one-time load of a legacy sort mode.
struct ProjectOrderTests {
  private let a = Project(name: "a", rootPath: "/a")
  private let b = Project(name: "b", rootPath: "/b")
  private let c = Project(name: "c", rootPath: "/c")
  private let hidden1 = Project(name: "h1", rootPath: "/h1")
  private let hidden2 = Project(name: "h2", rootPath: "/h2")

  // MARK: - Drop resolution

  @Test
  func dropResolvesToBeforeTheVisibleProjectBelowTheBoundary() {
    let placement = ProjectPlacement.resolve(moving: c.id, visible: [a.id, b.id, c.id], boundary: 1)
    #expect(placement == .before(b.id))
  }

  @Test
  func dropAtFirstPositionResolvesToBeforeFirstVisible() {
    let placement = ProjectPlacement.resolve(moving: c.id, visible: [a.id, b.id, c.id], boundary: 0)
    #expect(placement == .before(a.id))
  }

  @Test
  func dropAtLastPositionResolvesToAfterLastVisible() {
    let placement = ProjectPlacement.resolve(moving: a.id, visible: [a.id, b.id, c.id], boundary: 3)
    #expect(placement == .after(c.id))
  }

  @Test
  func dropOnEitherSideOfTheDraggedBlockIsNoMove() {
    let visible = [a.id, b.id, c.id]
    #expect(ProjectPlacement.resolve(moving: b.id, visible: visible, boundary: 1) == nil)
    #expect(ProjectPlacement.resolve(moving: b.id, visible: visible, boundary: 2) == nil)
  }

  @Test
  func dropWithNothingVisibleIsNoMove() {
    #expect(ProjectPlacement.resolve(moving: a.id, visible: [], boundary: 0) == nil)
  }

  @Test
  func outOfRangeBoundaryClampsToTheEnds() {
    let visible = [a.id, b.id]
    #expect(ProjectPlacement.resolve(moving: c.id, visible: visible, boundary: -4) == .before(a.id))
    #expect(ProjectPlacement.resolve(moving: c.id, visible: visible, boundary: 9) == .after(b.id))
  }

  // MARK: - Move on the full list

  @Test
  func moveBeforeVisibleNeighborKeepsHiddenProjectsInPlace() {
    var catalog = Catalog(projects: [a, hidden1, b, hidden2, c])
    let placement = ProjectPlacement.resolve(moving: c.id, visible: [a.id, b.id, c.id], boundary: 1)
    #expect(placement.map { catalog.moveProject(c.id, to: $0) } == true)
    #expect(catalog.projects.map(\.name) == ["a", "h1", "c", "b", "h2"])
  }

  @Test
  func moveToFirstPositionUnderFilterGoesBeforeFirstVisibleNotBeforeHidden() {
    var catalog = Catalog(projects: [hidden1, a, b, hidden2, c])
    let placement = ProjectPlacement.resolve(moving: c.id, visible: [a.id, b.id, c.id], boundary: 0)
    #expect(placement.map { catalog.moveProject(c.id, to: $0) } == true)
    #expect(catalog.projects.map(\.name) == ["h1", "c", "a", "b", "h2"])
  }

  @Test
  func moveToLastPositionUnderFilterGoesAfterLastVisible() {
    var catalog = Catalog(projects: [a, hidden1, b, c, hidden2])
    let placement = ProjectPlacement.resolve(moving: a.id, visible: [a.id, b.id, c.id], boundary: 3)
    #expect(placement.map { catalog.moveProject(a.id, to: $0) } == true)
    #expect(catalog.projects.map(\.name) == ["h1", "b", "c", "a", "h2"])
  }

  @Test
  func moveOntoItselfOrToSamePositionChangesNothing() {
    var catalog = Catalog(projects: [a, b, c])
    let movedOntoSelf = catalog.moveProject(b.id, to: .before(b.id))
    #expect(!movedOntoSelf)
    let movedAfterPrevious = catalog.moveProject(b.id, to: .after(a.id))
    #expect(!movedAfterPrevious)
    let movedBeforeNext = catalog.moveProject(b.id, to: .before(c.id))
    #expect(!movedBeforeNext)
    #expect(catalog.projects.map(\.name) == ["a", "b", "c"])
  }

  @Test
  func moveWithUnknownIDChangesNothing() {
    var catalog = Catalog(projects: [a, b])
    let movedUnknown = catalog.moveProject(c.id, to: .before(a.id))
    #expect(!movedUnknown)
    let movedAfterUnknown = catalog.moveProject(a.id, to: .after(c.id))
    #expect(!movedAfterUnknown)
    #expect(catalog.projects.map(\.name) == ["a", "b"])
  }

  @Test
  func moveKeepsTheBlockContentAndExpansionState() {
    let worktree = Worktree(name: "feat", path: "/b-feat", branch: "feat", tabs: [], selectedTabID: nil)
    let expanded = Project(name: "b", rootPath: "/b", worktrees: [worktree], isExpanded: true)
    let collapsed = Project(name: "c", rootPath: "/c", isExpanded: false)
    var catalog = Catalog(projects: [a, expanded, collapsed])
    catalog.moveProject(expanded.id, to: .before(a.id))
    catalog.moveProject(collapsed.id, to: .before(a.id))
    #expect(catalog.projects == [expanded, collapsed, a])
  }

  @Test
  func sidebarSlotsFollowTheArrayOrderNotAddedAt() {
    let older = folderProject("older", addedAt: date(1))
    let newer = folderProject("newer", addedAt: date(2))
    let catalog = Catalog(projects: [newer, older])
    #expect(catalog.sidebarProjects.map(\.id) == [newer.id, older.id])
    #expect(catalog.sidebarSelectionOrder.map(\.projectID) == [newer.id, older.id])
  }

  // MARK: - Load-time materialization

  @Test
  func joinOrderCatalogLoadsSortedByAddedAt() throws {
    let projects = [
      Project(name: "c", rootPath: "/c", addedAt: date(3)),
      Project(name: "a", rootPath: "/a", addedAt: .distantPast),
      Project(name: "b", rootPath: "/b", addedAt: date(2)),
      Project(name: "a2", rootPath: "/a2", addedAt: .distantPast),
    ]
    let catalog = try decodeLegacy(projects, sortMode: "joinOrder")
    #expect(catalog.projects.map(\.name) == ["a", "a2", "b", "c"])
  }

  @Test
  func activeFirstCatalogLoadsMostRecentFirstThenAddedAt() throws {
    let projects = [
      Project(name: "a", rootPath: "/a", addedAt: date(1), lastActiveAt: date(50)),
      Project(name: "d", rootPath: "/d", addedAt: date(4)),
      Project(name: "b", rootPath: "/b", addedAt: date(2), lastActiveAt: date(99)),
      Project(name: "c", rootPath: "/c", addedAt: date(3)),
    ]
    let catalog = try decodeLegacy(projects, sortMode: "activeFirst")
    #expect(catalog.projects.map(\.name) == ["b", "a", "c", "d"])
  }

  @Test
  func manualCatalogLoadsSortedByManualOrderWithArrayTiebreak() throws {
    let catalog = try decodeLegacy([a, b, c, hidden1], sortMode: "manual", manualOrders: [2, 0, 1, 0])
    #expect(catalog.projects.map(\.name) == ["b", "h1", "c", "a"])
  }

  @Test
  func legacyCatalogWithoutSortModeLoadsSortedByAddedAt() throws {
    // The old encoder omitted the default `joinOrder`, and the old sidebar
    // still sorted by `addedAt`: the array alone was not the visible order.
    let projects = [
      Project(name: "c", rootPath: "/c", addedAt: date(3)),
      Project(name: "a", rootPath: "/a", addedAt: date(1)),
      Project(name: "b", rootPath: "/b", addedAt: date(2)),
    ]
    let catalog = try decodeLegacy(projects, sortMode: nil)
    #expect(catalog.projects.map(\.name) == ["a", "b", "c"])
  }

  @Test
  func catalogWrittenUnderADR0001KeepsArrayOrderAgainstAddedAt() throws {
    var catalog = Catalog(projects: [
      Project(name: "a", rootPath: "/a", addedAt: date(1)),
      Project(name: "b", rootPath: "/b", addedAt: date(2)),
    ])
    let b = catalog.projects[1].id
    catalog.moveProject(b, to: .before(catalog.projects[0].id))
    let decoded = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(catalog))
    #expect(decoded.projects.map(\.name) == ["b", "a"])
  }

  @Test
  func encoderMarksTheArrayAsTheProjectOrder() throws {
    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(Catalog())) as? [String: Any])
    #expect(object["projectOrder"] as? String == "array")
  }

  // A present order field must be valid: guessing on a bad value would sort
  // the array and persist that order on the next save.

  @Test(arguments: [#""byName""#, "7", "null"])
  func anInvalidSortModeFailsTheDecode(value: String) throws {
    #expect(throws: DecodingError.self) {
      _ = try decodeEdited { object in object["projectSortMode"] = json(value) }
    }
  }

  @Test(arguments: [#""stack""#, "true", "null"])
  func anInvalidOrderMarkerFailsTheDecode(value: String) throws {
    #expect(throws: DecodingError.self) {
      _ = try decodeEdited { object in object["projectOrder"] = json(value) }
    }
  }

  @Test(arguments: [#""first""#, "null"])
  func anInvalidManualOrderFailsTheDecode(value: String) throws {
    #expect(throws: DecodingError.self) {
      _ = try decodeEdited(legacy: true) { object in
        object["projectSortMode"] = "manual"
        var projects = object["projects"] as? [[String: Any]] ?? []
        projects[0]["manualOrder"] = json(value)
        object["projects"] = projects
      }
    }
  }

  @Test(arguments: ["joinOrder", "activeFirst", "manual"])
  func saveAfterLegacyLoadWritesNeitherModeNorManualOrder(sortMode: String) throws {
    let catalog = try decodeLegacy([a, b], sortMode: sortMode, manualOrders: [1, 2])
    let json = String(bytes: try JSONEncoder().encode(catalog), encoding: .utf8) ?? ""
    #expect(!json.contains("projectSortMode"))
    #expect(!json.contains("manualOrder"))
    #expect(json.contains(#""projectOrder":"array""#))
    #expect(try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(catalog)) == catalog)
  }

  @Test
  func projectAddedAtAndLastActiveAtRoundTrip() throws {
    let project = Project(name: "p", rootPath: "/p", addedAt: date(100), lastActiveAt: date(200))
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(decoded.addedAt == date(100))
    #expect(decoded.lastActiveAt == date(200))
  }

  // MARK: - Helpers

  /// Encodes `projects` the way a pre-ADR-0001 build wrote them: no
  /// `projectOrder` marker, the catalog names `sortMode` (or omits the default
  /// `joinOrder`), and each Project carries its `manualOrder`.
  private func decodeLegacy(
    _ projects: [Project], sortMode: String?, manualOrders: [Int]? = nil
  ) throws -> Catalog {
    let data = try JSONEncoder().encode(Catalog(projects: projects))
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "projectOrder")
    if let sortMode { object["projectSortMode"] = sortMode }
    if let manualOrders {
      var encoded = try #require(object["projects"] as? [[String: Any]])
      for index in encoded.indices { encoded[index]["manualOrder"] = manualOrders[index] }
      object["projects"] = encoded
    }
    return try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: object))
  }

  /// A plain-folder Project: its row stands for a worktree, so it claims a
  /// ⌃-slot.
  private func folderProject(_ name: String, addedAt: Date) -> Project {
    let root = Worktree(name: name, path: "/\(name)")
    return Project(name: name, rootPath: "/\(name)", worktrees: [root], addedAt: addedAt, loadState: .ready)
  }

  /// Encodes a two-Project catalog, edits its JSON, and decodes it.
  /// `legacy` drops the `projectOrder` marker first.
  private func decodeEdited(legacy: Bool = false, _ edit: (inout [String: Any]) -> Void) throws -> Catalog {
    let data = try JSONEncoder().encode(Catalog(projects: [a, b]))
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    if legacy { object.removeValue(forKey: "projectOrder") }
    edit(&object)
    return try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func json(_ fragment: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(fragment.utf8), options: .fragmentsAllowed)) ?? NSNull()
  }

  private func date(_ secondsSince1970: TimeInterval) -> Date {
    Date(timeIntervalSince1970: secondsSince1970)
  }
}
