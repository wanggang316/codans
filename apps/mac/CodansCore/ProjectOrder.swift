import Foundation

/// Where a dragged Project goes, relative to a visible Project. Resolved by
/// `ProjectID`, not by row index, so a filtered sidebar cannot point the move
/// at the wrong Project (ADR 0001).
public nonisolated enum ProjectPlacement: Equatable, Sendable {
  case before(ProjectID)
  case after(ProjectID)

  /// Resolves a drop on the boundary at `boundary` between the visible
  /// Project blocks: `0` is above the first block, `visible.count` is below
  /// the last one. Returns `nil` when the drop does not move the Project
  /// (a boundary next to the dragged block, or nothing is visible).
  public static func resolve(
    moving projectID: ProjectID,
    visible: [ProjectID],
    boundary: Int
  ) -> ProjectPlacement? {
    guard let last = visible.last else { return nil }
    let boundary = min(max(boundary, 0), visible.count)
    if let index = visible.firstIndex(of: projectID), boundary == index || boundary == index + 1 {
      return nil
    }
    return boundary < visible.count ? .before(visible[boundary]) : .after(last)
  }
}

extension Catalog {
  /// Moves one Project in `projects`. Every other Project, hidden by a filter
  /// or not, keeps its relative position. Returns `false` when nothing
  /// changed: an unknown id, a drop on itself, or the same position.
  @discardableResult
  public mutating func moveProject(_ projectID: ProjectID, to placement: ProjectPlacement) -> Bool {
    let targetID: ProjectID
    switch placement {
    case .before(let id), .after(let id): targetID = id
    }
    guard projectID != targetID,
      let sourceIndex = projects.firstIndex(where: { $0.id == projectID }),
      projects.contains(where: { $0.id == targetID })
    else { return false }
    var reordered = projects
    let moved = reordered.remove(at: sourceIndex)
    guard let targetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return false }
    switch placement {
    case .before: reordered.insert(moved, at: targetIndex)
    case .after: reordered.insert(moved, at: targetIndex + 1)
    }
    guard reordered.map(\.id) != projects.map(\.id) else { return false }
    projects = reordered
    return true
  }
}

/// The retired sort modes (`joinOrder`, `activeFirst`, `manual`) and the
/// per-Project `manualOrder` key. A catalog without the `projectOrder` marker
/// is sorted one time at load with its stored mode (`joinOrder` when none is
/// stored), so the order the user sees does not change. Neither key is
/// written again.
nonisolated enum LegacyProjectOrder {
  static let joinOrder = "joinOrder"
  static let activeFirst = "activeFirst"
  static let manual = "manual"
  /// Value of the catalog's `projectOrder` key in a file written under
  /// ADR 0001. Without it, the file comes from an older build.
  static let arrayMarker = "array"

  /// The one legacy key a Project carried for ordering.
  struct Fields: Decodable {
    let manualOrder: Int

    private enum CodingKeys: String, CodingKey { case manualOrder }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      manualOrder = try container.decodeIfPresent(Int.self, forKey: .manualOrder) ?? 0
    }
  }

  /// Sorts `projects` the way the retired `sortMode` displayed them. Ties
  /// keep the array order. `nil` (a file with the `projectOrder` marker) or an
  /// unknown mode keeps the array as is.
  static func materialize(_ projects: [Project], sortMode: String?, manualOrders: [Int]) -> [Project] {
    let areInIncreasingOrder: (Project, Project) -> Bool?
    switch sortMode {
    case joinOrder:
      areInIncreasingOrder = { lhs, rhs in
        lhs.addedAt == rhs.addedAt ? nil : lhs.addedAt < rhs.addedAt
      }
    case activeFirst:
      // Most recent activity first; never-active Projects follow, by addedAt.
      areInIncreasingOrder = { lhs, rhs in
        switch (lhs.lastActiveAt, rhs.lastActiveAt) {
        case (let left?, let right?) where left != right: return left > right
        case (.some, .none): return true
        case (.none, .some): return false
        default: return lhs.addedAt == rhs.addedAt ? nil : lhs.addedAt < rhs.addedAt
        }
      }
    case manual:
      guard manualOrders.count == projects.count else { return projects }
      return zip(projects, manualOrders).enumerated()
        .sorted { lhs, rhs in
          lhs.element.1 != rhs.element.1 ? lhs.element.1 < rhs.element.1 : lhs.offset < rhs.offset
        }
        .map(\.element.0)
    default:
      return projects
    }
    return projects.enumerated()
      .sorted { lhs, rhs in
        areInIncreasingOrder(lhs.element, rhs.element) ?? (lhs.offset < rhs.offset)
      }
      .map(\.element)
  }
}
