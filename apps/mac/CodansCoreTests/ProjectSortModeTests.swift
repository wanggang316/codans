import Foundation
import Testing

@testable import CodansCore

/// Exercises `Catalog.sorted(_:)` and `Catalog.projectID(forPane:)` —
/// the two pure helpers introduced for the sidebar bottom-bar
/// project sort. The reducer + manager pieces are covered separately
/// in HierarchyManager tests.
struct ProjectSortModeTests {
  // MARK: - Sort policies

  @Test
  func manualSortsByManualOrderField() {
    // Order in storage is arbitrary; sort follows the `manualOrder`
    // field exclusively.
    let a = Project(name: "a", rootPath: "/a", manualOrder: 2)
    let b = Project(name: "b", rootPath: "/b", manualOrder: 0)
    let c = Project(name: "c", rootPath: "/c", manualOrder: 1)
    let catalog = Catalog(
      projects: [a, b, c],
      projectSortMode: .manual
    )
    #expect(catalog.sorted(catalog.projects).map(\.name) == ["b", "c", "a"])
  }

  @Test
  func manualTiesOnZeroFallBackToArrayPosition() {
    // Legacy projects all decode to manualOrder = 0; the array order
    // must remain the user-visible order.
    let a = Project(name: "a", rootPath: "/a")
    let b = Project(name: "b", rootPath: "/b")
    let c = Project(name: "c", rootPath: "/c")
    let catalog = Catalog(projects: [a, b, c], projectSortMode: .manual)
    #expect(catalog.sorted(catalog.projects).map(\.name) == ["a", "b", "c"])
  }

  @Test
  func joinOrderSortsByAddedAtAscending() {
    let a = Project(name: "a", rootPath: "/a", addedAt: date(3))
    let b = Project(name: "b", rootPath: "/b", addedAt: date(1))
    let c = Project(name: "c", rootPath: "/c", addedAt: date(2))
    let catalog = Catalog(
      projects: [a, b, c],
      projectSortMode: .joinOrder
    )
    #expect(catalog.sorted(catalog.projects).map(\.name) == ["b", "c", "a"])
  }

  @Test
  func joinOrderUsesArrayPositionForLegacyTies() {
    // Legacy decode → all addedAt = .distantPast → tiebreak by input
    // array order so an upgraded catalog renders identically to the
    // historical insertion order.
    let a = Project(name: "a", rootPath: "/a", addedAt: .distantPast)
    let b = Project(name: "b", rootPath: "/b", addedAt: .distantPast)
    let catalog = Catalog(projects: [a, b], projectSortMode: .joinOrder)
    #expect(catalog.sorted(catalog.projects).map(\.name) == ["a", "b"])
  }

  @Test
  func activeFirstPlacesMostRecentFirstThenAddedAt() {
    // active(b) > active(a); c has no activity → falls through to
    // addedAt-asc tiebreaker.
    let a = Project(
      name: "a", rootPath: "/a", addedAt: date(1), lastActiveAt: date(50)
    )
    let b = Project(
      name: "b", rootPath: "/b", addedAt: date(2), lastActiveAt: date(99)
    )
    let c = Project(name: "c", rootPath: "/c", addedAt: date(3))
    let d = Project(name: "d", rootPath: "/d", addedAt: date(4))
    let catalog = Catalog(
      projects: [a, b, c, d],
      projectSortMode: .activeFirst
    )
    #expect(catalog.sorted(catalog.projects).map(\.name) == ["b", "a", "c", "d"])
  }

  // MARK: - Codable round-trip

  @Test
  func nonDefaultSortModeRoundTrips() throws {
    let catalog = Catalog(
      projects: [],
      projectSortMode: .activeFirst
    )
    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded.projectSortMode == .activeFirst)
  }

  @Test
  func defaultSortModeIsOmittedFromEncoding() throws {
    let catalog = Catalog(
      projects: [],
      projectSortMode: .joinOrder
    )
    let data = try JSONEncoder().encode(catalog)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("projectSortMode"))
  }

  @Test
  func missingSortModeDecodesToDefault() throws {
    let payload = Data(#"{"version": 3}"#.utf8)
    let catalog = try JSONDecoder().decode(Catalog.self, from: payload)
    #expect(catalog.projectSortMode == .joinOrder)
  }

  @Test
  func projectAddedAtAndLastActiveAtRoundTrip() throws {
    let project = Project(
      name: "p",
      rootPath: "/p",
      addedAt: date(100),
      lastActiveAt: date(200),
      manualOrder: 7
    )
    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded.addedAt == date(100))
    #expect(decoded.lastActiveAt == date(200))
    #expect(decoded.manualOrder == 7)
  }

  @Test
  func defaultManualOrderIsOmittedFromEncoding() throws {
    let project = Project(name: "p", rootPath: "/p", manualOrder: 0)
    let data = try JSONEncoder().encode(project)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("manualOrder"))
  }

  @Test
  func legacyProjectAddedAtDefaultsToDistantPast() throws {
    // No addedAt key — emulates an existing catalog.json from before
    // the sort-mode feature shipped. Defensive decode: never throw,
    // never lose data; just fall through to the sentinel.
    let payload = Data(#"""
      {
        "id": { "raw": "11111111-1111-1111-1111-111111111111" },
        "name": "p",
        "rootPath": "/p"
      }
      """#.utf8)
    let decoded = try JSONDecoder().decode(Project.self, from: payload)
    #expect(decoded.addedAt == .distantPast)
    #expect(decoded.lastActiveAt == nil)
    #expect(decoded.manualOrder == 0)
  }

  // MARK: - Helpers

  private func date(_ secondsSince1970: TimeInterval) -> Date {
    Date(timeIntervalSince1970: secondsSince1970)
  }
}
