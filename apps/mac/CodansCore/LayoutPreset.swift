import CoreGraphics
import Foundation

/// A named shape for all Panes of a Tab (GLOSSARY: Layout preset). The
/// presets offered depend on the Pane count; `rawValue` is the stable
/// identifier. Even presets keep the Pane order. Main presets put the
/// focused Pane in the main area (half of the Tab) and the other Panes in
/// Pane order, sharing the other half evenly.
public nonisolated enum LayoutPreset: String, CaseIterable, Codable, Sendable {
  case columns
  case columnsTwoToOne = "columns-2-1"
  case columnsOneToTwo = "columns-1-2"
  case rows
  case rowsTwoToOne = "rows-2-1"
  case rowsOneToTwo = "rows-1-2"
  case grid
  case mainLeft = "main-left"
  case mainRight = "main-right"
  case mainTop = "main-top"
  case mainBottom = "main-bottom"

  public var id: String { rawValue }

  public var isMain: Bool {
    switch self {
    case .mainLeft, .mainRight, .mainTop, .mainBottom: true
    default: false
    }
  }

  /// The presets for a Tab with `paneCount` Panes, in display order. Empty
  /// for fewer than two Panes.
  public static func presets(forPaneCount paneCount: Int) -> [LayoutPreset] {
    switch paneCount {
    case ..<2: []
    case 2: [.columns, .columnsTwoToOne, .columnsOneToTwo, .rows, .rowsTwoToOne, .rowsOneToTwo]
    case 3: [.columns, .rows, .mainLeft, .mainRight, .mainTop, .mainBottom]
    case 4: [.grid, .columns, .rows, .mainLeft, .mainTop]
    default: [.columns, .rows, .grid, .mainLeft, .mainTop]
    }
  }

  public func title(forPaneCount paneCount: Int) -> String {
    switch self {
    case .columns: paneCount == 2 ? "Columns 1:1" : "Columns"
    case .columnsTwoToOne: "Columns 2:1"
    case .columnsOneToTwo: "Columns 1:2"
    case .rows: paneCount == 2 ? "Rows 1:1" : "Rows"
    case .rowsTwoToOne: "Rows 2:1"
    case .rowsOneToTwo: "Rows 1:2"
    case .grid:
      "Grid \(Self.gridColumnCount(paneCount))×\(Self.gridRowSizes(paneCount).count)"
    case .mainLeft: "Main Left"
    case .mainRight: "Main Right"
    case .mainTop: "Main Top"
    case .mainBottom: "Main Bottom"
    }
  }

  /// A grid of N Panes uses ⌈√N⌉ columns.
  static func gridColumnCount(_ paneCount: Int) -> Int {
    guard paneCount > 0 else { return 0 }
    var columns = 1
    while columns * columns < paneCount { columns += 1 }
    return columns
  }

  /// Pane count of each grid row; the last row holds the remainder.
  static func gridRowSizes(_ paneCount: Int) -> [Int] {
    let columns = gridColumnCount(paneCount)
    guard columns > 0 else { return [] }
    return stride(from: 0, to: paneCount, by: columns).map { min(columns, paneCount - $0) }
  }
}

// MARK: - Arrange and match

extension SplitTree {
  /// Default ratio tolerance for `matchingPreset`, in fractions of the Tab.
  public static var presetMatchTolerance: Double { 0.01 }

  /// Returns this tree arranged with `preset`. The leaf set is unchanged and
  /// zoom is cleared. A tree with fewer than two leaves is returned as is.
  ///
  /// - Parameter focus: The focused leaf. Main presets put it in the main
  ///   area and need it; even presets ignore it.
  /// - Throws: `presetUnavailable` when the preset is not offered for the
  ///   leaf count; `leafNotFound` when a main preset gets no focus in the tree.
  public func arranged(_ preset: LayoutPreset, focus: Leaf?) throws -> Self {
    let leaves = leaves()
    guard leaves.count >= 2 else { return self }
    guard LayoutPreset.presets(forPaneCount: leaves.count).contains(preset) else {
      throw SplitError.presetUnavailable
    }
    return Self(root: try Self.presetNode(preset, leaves: leaves, focus: focus), zoomed: nil)
  }

  /// The preset whose layout equals this tree: the same frame for each leaf,
  /// within `tolerance`. Frames, not node structure, are compared, so any
  /// partition that draws the same layout matches. `nil` when no preset
  /// matches or the tree has fewer than two leaves.
  public func matchingPreset(tolerance: Double = presetMatchTolerance) -> LayoutPreset? {
    guard let root else { return nil }
    let leaves = leaves()
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let actual = Dictionary(
      root.spatialLeafSlots(in: unit).map { ($0.leaf, $0.bounds) }, uniquingKeysWith: { lhs, _ in lhs })
    func matches(_ candidate: Node) -> Bool {
      candidate.spatialLeafSlots(in: unit).allSatisfy { slot in
        guard let frame = actual[slot.leaf] else { return false }
        return abs(frame.minX - slot.bounds.minX) <= tolerance
          && abs(frame.minY - slot.bounds.minY) <= tolerance
          && abs(frame.maxX - slot.bounds.maxX) <= tolerance
          && abs(frame.maxY - slot.bounds.maxY) <= tolerance
      }
    }
    return LayoutPreset.presets(forPaneCount: leaves.count).first { preset in
      // A main preset matches with whichever leaf is in its main area.
      let mainCandidates: [Leaf?] = preset.isMain ? leaves.map { $0 } : [nil]
      return mainCandidates.contains { focus in
        guard let candidate = try? Self.presetNode(preset, leaves: leaves, focus: focus) else { return false }
        return matches(candidate)
      }
    }
  }

  private static func presetNode(_ preset: LayoutPreset, leaves: [Leaf], focus: Leaf?) throws -> Node {
    switch preset {
    case .columns: return evenNode(leaves[...], direction: .horizontal)
    case .rows: return evenNode(leaves[...], direction: .vertical)
    case .columnsTwoToOne: return pairNode(leaves, direction: .horizontal, ratio: 2.0 / 3)
    case .columnsOneToTwo: return pairNode(leaves, direction: .horizontal, ratio: 1.0 / 3)
    case .rowsTwoToOne: return pairNode(leaves, direction: .vertical, ratio: 2.0 / 3)
    case .rowsOneToTwo: return pairNode(leaves, direction: .vertical, ratio: 1.0 / 3)
    case .grid:
      var rest = leaves[...]
      let rows = LayoutPreset.gridRowSizes(leaves.count).map { size in
        defer { rest = rest.dropFirst(size) }
        return evenNode(rest.prefix(size), direction: .horizontal)
      }
      return evenNode(rows[...], direction: .vertical)
    case .mainLeft, .mainRight, .mainTop, .mainBottom:
      guard let focus, leaves.contains(focus) else { throw SplitError.leafNotFound }
      let others = evenNode(
        leaves.filter { $0 != focus }[...],
        direction: preset == .mainLeft || preset == .mainRight ? .vertical : .horizontal)
      let main: Node = .leaf(focus)
      let mainFirst = preset == .mainLeft || preset == .mainTop
      return .split(
        Split(
          direction: preset == .mainLeft || preset == .mainRight ? .horizontal : .vertical,
          ratio: 0.5,
          left: mainFirst ? main : others,
          right: mainFirst ? others : main))
    }
  }

  private static func pairNode(_ leaves: [Leaf], direction: Direction, ratio: Double) -> Node {
    .split(Split(direction: direction, ratio: ratio, left: .leaf(leaves[0]), right: .leaf(leaves[1])))
  }

  private static func evenNode(_ leaves: ArraySlice<Leaf>, direction: Direction) -> Node {
    evenNode(leaves.map { Node.leaf($0) }[...], direction: direction)
  }

  /// Nested binary splits whose ratios give each node 1/k of the area.
  private static func evenNode(_ nodes: ArraySlice<Node>, direction: Direction) -> Node {
    guard nodes.count > 1 else { return nodes[nodes.startIndex] }
    let leftCount = nodes.count / 2
    return .split(
      Split(
        direction: direction,
        ratio: Double(leftCount) / Double(nodes.count),
        left: evenNode(nodes.prefix(leftCount), direction: direction),
        right: evenNode(nodes.dropFirst(leftCount), direction: direction)))
  }
}
