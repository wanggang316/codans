import Foundation

/// Arrow-key movement in the thumbnail grid that the Layout picker and the
/// Place picker share. Items fill rows of `columns` from the top left.
enum PickerGrid {
  enum Direction: Equatable { case left, right, up, down }

  /// The item that an arrow key moves to in a grid of `count` items,
  /// `columns` per row, or `nil` at an edge. There is no wrap: Left and Right
  /// stay in the row, Up and Down stay in the column, so a held arrow key
  /// settles on an edge.
  static func index(moving direction: Direction, from index: Int, count: Int, columns: Int) -> Int? {
    let column = index % columns
    let target: Int
    switch direction {
    case .left:
      guard column > 0 else { return nil }
      target = index - 1
    case .right:
      guard column < columns - 1 else { return nil }
      target = index + 1
    case .up:
      target = index - columns
    case .down:
      target = index + columns
    }
    return (0..<count).contains(target) ? target : nil
  }
}

/// One Pane region of a picker thumbnail, in the unit square, labelled with
/// its Pane number. The focused Pane's region is tinted.
struct PickerSlot: Equatable {
  let paneNumber: Int
  let bounds: CGRect
  let isFocused: Bool
}
