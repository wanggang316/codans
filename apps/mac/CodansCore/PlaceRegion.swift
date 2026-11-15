import Foundation

/// A region of a Tab that Place moves the focused Pane into: a half, a third,
/// or two thirds, in the horizontal or the vertical direction (GLOSSARY: Place).
///
/// Raw values are stable identifiers. The Command Palette, the menus, and the
/// shortcut registry key their items on them.
public nonisolated enum PlaceRegion: String, CaseIterable, Hashable, Sendable, Codable {
  case leftHalf
  case rightHalf
  case topHalf
  case bottomHalf
  case leftThird
  case centerThird
  case rightThird
  case topThird
  case middleThird
  case bottomThird
  case leftTwoThirds
  case rightTwoThirds
  case topTwoThirds
  case bottomTwoThirds

  /// Where the region sits along its direction.
  public enum Position: Sendable, Equatable { case first, center, last }

  /// How much of the Tab the region takes along its direction.
  public enum Span: Sendable, Equatable {
    case half, third, twoThirds

    public var fraction: Double {
      switch self {
      case .half: 1.0 / 2.0
      case .third: 1.0 / 3.0
      case .twoThirds: 2.0 / 3.0
      }
    }
  }

  /// `true` for left / center / right regions (a vertical seam), `false` for
  /// top / middle / bottom regions (a horizontal seam).
  public var isHorizontal: Bool {
    switch self {
    case .leftHalf, .rightHalf, .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
      true
    case .topHalf, .bottomHalf, .topThird, .middleThird, .bottomThird, .topTwoThirds, .bottomTwoThirds:
      false
    }
  }

  public var position: Position {
    switch self {
    case .leftHalf, .topHalf, .leftThird, .topThird, .leftTwoThirds, .topTwoThirds: .first
    case .centerThird, .middleThird: .center
    case .rightHalf, .bottomHalf, .rightThird, .bottomThird, .rightTwoThirds, .bottomTwoThirds: .last
    }
  }

  public var span: Span {
    switch self {
    case .leftHalf, .rightHalf, .topHalf, .bottomHalf: .half
    case .leftThird, .centerThird, .rightThird, .topThird, .middleThird, .bottomThird: .third
    case .leftTwoThirds, .rightTwoThirds, .topTwoThirds, .bottomTwoThirds: .twoThirds
    }
  }

  /// Menu and Command Palette title, for example "Left Half".
  public var title: String {
    switch self {
    case .leftHalf: "Left Half"
    case .rightHalf: "Right Half"
    case .topHalf: "Top Half"
    case .bottomHalf: "Bottom Half"
    case .leftThird: "Left Third"
    case .centerThird: "Center Third"
    case .rightThird: "Right Third"
    case .topThird: "Top Third"
    case .middleThird: "Middle Third"
    case .bottomThird: "Bottom Third"
    case .leftTwoThirds: "Left Two Thirds"
    case .rightTwoThirds: "Right Two Thirds"
    case .topTwoThirds: "Top Two Thirds"
    case .bottomTwoThirds: "Bottom Two Thirds"
    }
  }

  /// Menu order, one inner array per separator-delimited group.
  public static let groups: [[PlaceRegion]] = [
    [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
    [.leftThird, .centerThird, .rightThird],
    [.topThird, .middleThird, .bottomThird],
    [.leftTwoThirds, .rightTwoThirds],
    [.topTwoThirds, .bottomTwoThirds],
  ]
}
