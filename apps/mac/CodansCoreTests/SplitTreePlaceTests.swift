import Foundation
import Testing

@testable import CodansCore

private func leaf(_ id: PaneID) -> SplitTree<PaneID>.Node { .leaf(id) }

private func split(
  _ direction: SplitTree<PaneID>.Direction, _ ratio: Double,
  _ left: SplitTree<PaneID>.Node, _ right: SplitTree<PaneID>.Node
) -> SplitTree<PaneID>.Node {
  .split(SplitTree<PaneID>.Split(direction: direction, ratio: ratio, left: left, right: right))
}

struct SplitTreePlaceTests {
  typealias Tree = SplitTree<PaneID>
  typealias Node = Tree.Node

  /// Panes a…d and three start shapes that hold all four.
  private struct Fixture {
    let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()

    /// a | b | c | d as nested horizontal splits.
    var columns: Node {
      split(
        .horizontal, 0.25, leaf(a),
        split(.horizontal, 1.0 / 3.0, leaf(b), split(.horizontal, 0.5, leaf(c), leaf(d))))
    }

    /// (a / b) | (c / d): a 2×2 grid.
    var grid: Node {
      split(.horizontal, 0.5, split(.vertical, 0.5, leaf(a), leaf(b)), split(.vertical, 0.5, leaf(c), leaf(d)))
    }

    /// a over (b | (c / d)).
    var mixed: Node {
      split(.vertical, 0.4, leaf(a), split(.horizontal, 0.6, leaf(b), split(.vertical, 0.7, leaf(c), leaf(d))))
    }

    var shapes: [Node] { [columns, grid, mixed] }
  }

  private static func expectedRatio(_ region: PlaceRegion) -> Double {
    switch (region.position, region.span) {
    case (.first, let span): span.fraction
    case (.last, let span): 1 - span.fraction
    case (.center, _): 1.0 / 3.0
    }
  }

  // MARK: - Every region from several start shapes

  @Test(arguments: PlaceRegion.allCases)
  func everyRegionGivesTheFocusedPaneItsRegion(region: PlaceRegion) throws {
    let f = Fixture()
    for shape in f.shapes {
      for focused in [f.a, f.b, f.c, f.d] {
        let before = Tree(root: shape)
        let after = try before.placing(focused, in: region)

        #expect(Set(after.leaves()) == Set(before.leaves()), "leaf set changed for \(region)")
        #expect(after.leaves().count == before.leaves().count)

        guard case .split(let root) = after.root else {
          Issue.record("expected a root split for \(region)")
          continue
        }
        #expect(root.direction == (region.isHorizontal ? .horizontal : .vertical))
        #expect(abs(root.ratio - Self.expectedRatio(region)) < 1e-9)

        switch region.position {
        case .first:
          #expect(root.left == .leaf(focused))
        case .last:
          #expect(root.right == .leaf(focused))
        case .center:
          guard case .split(let inner) = root.right else {
            Issue.record("center third needs a nested split")
            continue
          }
          #expect(inner.direction == root.direction)
          #expect(abs(inner.ratio - 0.5) < 1e-9)
          #expect(inner.left == .leaf(focused))
        }
      }
    }
  }

  // MARK: - Relative structure of the other Panes

  @Test
  func otherPanesKeepTheirRelativeStructure() throws {
    let f = Fixture()
    let before = Tree(root: f.mixed)
    let after = try before.placing(f.a, in: .rightHalf)
    // The old tree without `a` is b | (c / d), unchanged, on the left.
    let rest = split(.horizontal, 0.6, leaf(f.b), split(.vertical, 0.7, leaf(f.c), leaf(f.d)))
    #expect(after.root == split(.horizontal, 0.5, rest, leaf(f.a)))
  }

  @Test
  func otherPanesKeepTheirStructureForADeepFocusedPane() throws {
    let f = Fixture()
    let after = try Tree(root: f.grid).placing(f.c, in: .topThird)
    let rest = split(.horizontal, 0.5, split(.vertical, 0.5, leaf(f.a), leaf(f.b)), leaf(f.d))
    #expect(after.root == split(.vertical, 1.0 / 3.0, leaf(f.c), rest))
  }

  @Test
  func centerThirdDividesTheOtherPanesAtTheirRootSplit() throws {
    let f = Fixture()
    let after = try Tree(root: f.grid).placing(f.a, in: .centerThird)
    // Without `a` the grid is b | (c / d); b goes to the left third and
    // (c / d) to the right third.
    let expected = split(
      .horizontal, 1.0 / 3.0, leaf(f.b),
      split(.horizontal, 0.5, leaf(f.a), split(.vertical, 0.5, leaf(f.c), leaf(f.d))))
    #expect(after.root == expected)
  }

  /// With one other Pane the center region cannot have Panes on both sides.
  /// Place still ends zoom, as every Place does, and keeps the shape.
  @Test
  func centerThirdWithOneOtherPaneOnlyEndsZoom() throws {
    let a = PaneID()
    let b = PaneID()
    let root = split(.horizontal, 0.5, leaf(a), leaf(b))
    let before = Tree(root: root, zoomed: a)
    #expect(try before.placing(a, in: .centerThird) == Tree(root: root))
    #expect(try before.placing(b, in: .middleThird) == Tree(root: root))
  }

  /// When the other Panes' root split runs across the region, its two parts go
  /// to the two sides: each part keeps its own subtree, and only the seam
  /// between the parts turns to the region's direction.
  @Test
  func centerThirdAcrossAPerpendicularRootSplitKeepsEachPart() throws {
    let f = Fixture()
    // a | ((b | c) / d): without `a` the root split is vertical.
    let before = Tree(
      root: split(
        .horizontal, 0.5, leaf(f.a),
        split(.vertical, 0.3, split(.horizontal, 0.4, leaf(f.b), leaf(f.c)), leaf(f.d))))
    let after = try before.placing(f.a, in: .centerThird)
    let expected = split(
      .horizontal, 1.0 / 3.0, split(.horizontal, 0.4, leaf(f.b), leaf(f.c)),
      split(.horizontal, 0.5, leaf(f.a), leaf(f.d)))
    #expect(after.root == expected)
  }

  // MARK: - Ratio-only path

  @Test
  func placeOnTheTargetShapeChangesOnlyTheRatio() throws {
    let f = Fixture()
    let rest = split(.vertical, 0.3, leaf(f.b), leaf(f.c))
    let before = Tree(root: split(.horizontal, 0.5, leaf(f.a), rest))
    let after = try before.placing(f.a, in: .leftTwoThirds)
    #expect(after.root == split(.horizontal, 2.0 / 3.0, leaf(f.a), rest))
  }

  @Test
  func placeOnTheCenterShapeChangesOnlyTheRatios() throws {
    let f = Fixture()
    let before = Tree(
      root: split(
        .vertical, 0.2, leaf(f.b), split(.vertical, 0.7, leaf(f.a), leaf(f.c))))
    let after = try before.placing(f.a, in: .middleThird)
    #expect(
      after.root
        == split(
          .vertical, 1.0 / 3.0, leaf(f.b), split(.vertical, 0.5, leaf(f.a), leaf(f.c))))
  }

  @Test
  func placeTwiceIsIdempotent() throws {
    let f = Fixture()
    for region in PlaceRegion.allCases {
      let once = try Tree(root: f.mixed).placing(f.b, in: region)
      #expect(try once.placing(f.b, in: region) == once, "second Place changed the tree for \(region)")
    }
  }

  // MARK: - Zoom, one Pane, unknown Pane

  @Test
  func placeClearsZoom() throws {
    let f = Fixture()
    let before = Tree(root: f.grid, zoomed: f.b)
    #expect(before.zoomed == f.b)
    let after = try before.placing(f.b, in: .leftHalf)
    #expect(after.zoomed == nil)
  }

  @Test(arguments: PlaceRegion.allCases)
  func onePaneTreeIsUnchanged(region: PlaceRegion) throws {
    let a = PaneID()
    let before = Tree(root: .leaf(a), zoomed: a)
    #expect(try before.placing(a, in: region) == before)
  }

  @Test
  func placeOfAnUnknownPaneThrows() {
    let f = Fixture()
    #expect(throws: Tree.SplitError.leafNotFound) {
      _ = try Tree(root: f.grid).placing(PaneID(), in: .leftHalf)
    }
  }
}
