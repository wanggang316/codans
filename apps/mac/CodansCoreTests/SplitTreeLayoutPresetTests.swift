import Foundation
import Testing

@testable import CodansCore

struct SplitTreeLayoutPresetTests {
  typealias Tree = SplitTree<PaneID>
  typealias Node = Tree.Node

  // MARK: - Fixtures

  /// A chain of right splits, then the last leaf zoomed, so each test starts
  /// from a tree that differs from every preset and has zoom to clear.
  private static func tree(_ count: Int) throws -> (Tree, [PaneID]) {
    let ids = (0..<count).map { _ in PaneID() }
    var tree = Tree(leaf: ids[0])
    for index in 1..<count {
      tree = try tree.inserting(ids[index], at: ids[index - 1], direction: index.isMultiple(of: 2) ? .down : .right)
    }
    return (tree.settingZoomed(ids[count - 1]), ids)
  }

  /// The unit-square frame of each leaf, keyed by leaf.
  private static func frames(_ tree: Tree) -> [PaneID: CGRect] {
    var result: [PaneID: CGRect] = [:]
    func walk(_ node: Node, _ rect: CGRect) {
      switch node {
      case .leaf(let leaf): result[leaf] = rect
      case .split(let split):
        switch split.direction {
        case .horizontal:
          let width = rect.width * split.ratio
          walk(split.left, CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
          walk(
            split.right,
            CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        case .vertical:
          let height = rect.height * split.ratio
          walk(split.left, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height))
          walk(
            split.right,
            CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
        }
      }
    }
    if let root = tree.root { walk(root, CGRect(x: 0, y: 0, width: 1, height: 1)) }
    return result
  }

  private static func close(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-9 }

  private static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    close(lhs.minX, rhs.minX) && close(lhs.minY, rhs.minY)
      && close(lhs.width, rhs.width) && close(lhs.height, rhs.height)
  }

  // MARK: - Preset lists

  @Test
  func presetsForEachPaneCount() {
    #expect(LayoutPreset.presets(forPaneCount: 0).isEmpty)
    #expect(LayoutPreset.presets(forPaneCount: 1).isEmpty)
    #expect(
      LayoutPreset.presets(forPaneCount: 2) == [
        .columns, .columnsTwoToOne, .columnsOneToTwo, .rows, .rowsTwoToOne, .rowsOneToTwo,
      ])
    #expect(
      LayoutPreset.presets(forPaneCount: 3) == [
        .columns, .rows, .mainLeft, .mainRight, .mainTop, .mainBottom,
      ])
    #expect(LayoutPreset.presets(forPaneCount: 4) == [.grid, .columns, .rows, .mainLeft, .mainTop])
    for count in [5, 7, 12] {
      #expect(LayoutPreset.presets(forPaneCount: count) == [.columns, .rows, .grid, .mainLeft, .mainTop])
    }
  }

  @Test
  func presetIDsAreStable() {
    #expect(
      LayoutPreset.allCases.map(\.id) == [
        "columns", "columns-2-1", "columns-1-2", "rows", "rows-2-1", "rows-1-2",
        "grid", "main-left", "main-right", "main-top", "main-bottom",
      ])
    #expect(LayoutPreset(rawValue: "main-left") == .mainLeft)
  }

  @Test
  func titlesDependOnPaneCount() {
    #expect(LayoutPreset.columns.title(forPaneCount: 2) == "Columns 1:1")
    #expect(LayoutPreset.columnsTwoToOne.title(forPaneCount: 2) == "Columns 2:1")
    #expect(LayoutPreset.rowsOneToTwo.title(forPaneCount: 2) == "Rows 1:2")
    #expect(LayoutPreset.columns.title(forPaneCount: 3) == "Columns")
    #expect(LayoutPreset.grid.title(forPaneCount: 4) == "Grid 2×2")
    #expect(LayoutPreset.grid.title(forPaneCount: 5) == "Grid 3×2")
    #expect(LayoutPreset.grid.title(forPaneCount: 7) == "Grid 3×3")
    #expect(LayoutPreset.mainBottom.title(forPaneCount: 3) == "Main Bottom")
  }

  // MARK: - Arrange: every preset for N = 2, 3, 4, 5, 7

  @Test(arguments: [2, 3, 4, 5, 7])
  func everyPresetKeepsLeavesClearsZoomAndMatchesItself(count: Int) throws {
    let (tree, ids) = try Self.tree(count)
    let focus = ids[count / 2]
    for preset in LayoutPreset.presets(forPaneCount: count) {
      let arranged = try tree.arranged(preset, focus: focus)
      #expect(Set(arranged.leaves()) == Set(ids), "\(preset)")
      #expect(arranged.leaves().count == count, "\(preset)")
      #expect(arranged.zoomed == nil, "\(preset)")
      #expect(arranged.matchingPreset() == preset, "\(preset)")
      if preset.isMain {
        #expect(arranged.leaves().filter { $0 != focus } == ids.filter { $0 != focus }, "\(preset)")
      } else {
        #expect(arranged.leaves() == ids, "\(preset)")
      }
    }
  }

  @Test(arguments: [2, 3, 4, 5, 7])
  func evenColumnsAndRowsGiveEachPaneAnEqualShare(count: Int) throws {
    let (tree, ids) = try Self.tree(count)
    let columns = Self.frames(try tree.arranged(.columns, focus: nil))
    let rows = Self.frames(try tree.arranged(.rows, focus: nil))
    let share = 1.0 / Double(count)
    for (index, id) in ids.enumerated() {
      let offset = Double(index) * share
      #expect(Self.close(columns[id]!, CGRect(x: offset, y: 0, width: share, height: 1)))
      #expect(Self.close(rows[id]!, CGRect(x: 0, y: offset, width: 1, height: share)))
    }
  }

  @Test
  func twoPaneRatios() throws {
    let (tree, ids) = try Self.tree(2)
    let cases: [(LayoutPreset, CGRect)] = [
      (.columnsTwoToOne, CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)),
      (.columnsOneToTwo, CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)),
      (.rowsTwoToOne, CGRect(x: 0, y: 0, width: 1, height: 2.0 / 3)),
      (.rowsOneToTwo, CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3)),
    ]
    for (preset, first) in cases {
      let frames = Self.frames(try tree.arranged(preset, focus: nil))
      #expect(Self.close(frames[ids[0]]!, first), "\(preset)")
    }
  }

  @Test(arguments: [3, 4, 5, 7])
  func mainPresetsPutTheFocusedPaneInHalfTheTab(count: Int) throws {
    let (tree, ids) = try Self.tree(count)
    let focus = ids[1]
    let others = ids.filter { $0 != focus }
    let share = 1.0 / Double(count - 1)
    let expected: [(LayoutPreset, CGRect, (Int) -> CGRect)] = [
      (
        .mainLeft, CGRect(x: 0, y: 0, width: 0.5, height: 1),
        { CGRect(x: 0.5, y: Double($0) * share, width: 0.5, height: share) }
      ),
      (
        .mainRight, CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
        { CGRect(x: 0, y: Double($0) * share, width: 0.5, height: share) }
      ),
      (
        .mainTop, CGRect(x: 0, y: 0, width: 1, height: 0.5),
        { CGRect(x: Double($0) * share, y: 0.5, width: share, height: 0.5) }
      ),
      (
        .mainBottom, CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
        { CGRect(x: Double($0) * share, y: 0, width: share, height: 0.5) }
      ),
    ]
    for (preset, main, other) in expected where LayoutPreset.presets(forPaneCount: count).contains(preset) {
      let frames = Self.frames(try tree.arranged(preset, focus: focus))
      #expect(Self.close(frames[focus]!, main), "\(preset)")
      for (index, id) in others.enumerated() {
        #expect(Self.close(frames[id]!, other(index)), "\(preset) \(index)")
      }
    }
  }

  @Test(arguments: [(4, 2, [2, 2]), (5, 3, [3, 2]), (7, 3, [3, 3, 1])])
  func gridUsesCeilSqrtColumnsAndPutsTheRemainderLast(count: Int, columns: Int, rowSizes: [Int]) throws {
    let (tree, ids) = try Self.tree(count)
    let frames = Self.frames(try tree.arranged(.grid, focus: nil))
    let rowHeight = 1.0 / Double(rowSizes.count)
    var index = 0
    for (row, size) in rowSizes.enumerated() {
      for column in 0..<size {
        let width = 1.0 / Double(size)
        let expected = CGRect(x: Double(column) * width, y: Double(row) * rowHeight, width: width, height: rowHeight)
        #expect(Self.close(frames[ids[index]]!, expected), "pane \(index)")
        index += 1
      }
    }
    #expect(rowSizes[0] == columns)
  }

  @Test
  func onePaneTreeIsUnchanged() throws {
    let a = PaneID()
    let tree = Tree(leaf: a)
    for preset in LayoutPreset.allCases {
      #expect(try tree.arranged(preset, focus: a) == tree)
    }
    #expect(tree.matchingPreset() == nil)
    #expect(Tree().matchingPreset() == nil)
  }

  @Test
  func mainPresetNeedsAFocusedPaneInTheTree() throws {
    let (tree, _) = try Self.tree(3)
    #expect(throws: Tree.SplitError.leafNotFound) { _ = try tree.arranged(.mainLeft, focus: nil) }
    #expect(throws: Tree.SplitError.leafNotFound) { _ = try tree.arranged(.mainLeft, focus: PaneID()) }
  }

  @Test
  func presetNotOfferedForThePaneCountThrows() throws {
    let (tree, ids) = try Self.tree(2)
    #expect(throws: Tree.SplitError.presetUnavailable) { _ = try tree.arranged(.grid, focus: ids[0]) }
    let (five, fiveIDs) = try Self.tree(5)
    #expect(throws: Tree.SplitError.presetUnavailable) { _ = try five.arranged(.mainRight, focus: fiveIDs[0]) }
  }

  // MARK: - Matching

  @Test
  func matchingAcceptsRatiosWithinTolerance() throws {
    let a = PaneID()
    let b = PaneID()
    let near = Tree(root: .split(.init(direction: .horizontal, ratio: 0.505, left: .leaf(a), right: .leaf(b))))
    #expect(near.matchingPreset() == .columns)
    let twoThirds = Tree(root: .split(.init(direction: .horizontal, ratio: 0.66, left: .leaf(a), right: .leaf(b))))
    #expect(twoThirds.matchingPreset() == .columnsTwoToOne)
  }

  @Test
  func matchingRejectsRatiosOutsideTolerance() {
    let a = PaneID()
    let b = PaneID()
    let off = Tree(root: .split(.init(direction: .horizontal, ratio: 0.55, left: .leaf(a), right: .leaf(b))))
    #expect(off.matchingPreset() == nil)
    #expect(off.matchingPreset(tolerance: 0.06) == .columns)
  }

  @Test
  func matchingReturnsNilForATreeThatMatchesNoPreset() throws {
    // Chain of alternating splits: no preset has this shape.
    let (tree, _) = try Self.tree(4)
    #expect(tree.matchingPreset() == nil)
  }

  @Test
  func matchingFindsAMainPresetWhateverPaneIsInTheMainArea() throws {
    let (tree, ids) = try Self.tree(3)
    let arranged = try tree.arranged(.mainRight, focus: ids[0])
    #expect(arranged.leaves().last == ids[0])
    #expect(arranged.matchingPreset() == .mainRight)
  }

  @Test
  func matchingComparesPaneFramesSoAnyEqualPartitionMatches() {
    // ((a | b) | c) draws the same three even columns as the arranged
    // (a | (b | c)), so it matches too.
    let a = PaneID()
    let b = PaneID()
    let c = PaneID()
    let leftPair: Node = .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(a), right: .leaf(b)))
    let tree = Tree(root: .split(.init(direction: .horizontal, ratio: 2.0 / 3, left: leftPair, right: .leaf(c))))
    #expect(tree.matchingPreset() == .columns)
  }

  @Test
  func matchingChecksTheMainAreaSize() throws {
    let (tree, ids) = try Self.tree(3)
    let arranged = try tree.arranged(.mainLeft, focus: ids[0])
    guard case .split(let split) = arranged.root else {
      Issue.record("expected a split")
      return
    }
    let narrow = Tree(
      root: .split(.init(direction: split.direction, ratio: 0.4, left: split.left, right: split.right)))
    #expect(narrow.matchingPreset() == nil)
  }
}
