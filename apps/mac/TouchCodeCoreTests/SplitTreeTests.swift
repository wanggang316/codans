import Foundation
import Testing

@testable import TouchCodeCore

struct SplitTreeTests {
  @Test
  func emptyTreeHasNoLeaves() {
    let tree = SplitTree<PaneID>()
    #expect(tree.isEmpty)
    #expect(!tree.isSplit)
    #expect(tree.leaves().isEmpty)
  }

  @Test
  func singleLeafTree() {
    let a = PaneID()
    let tree = SplitTree(leaf: a)
    #expect(!tree.isEmpty)
    #expect(!tree.isSplit)
    #expect(tree.leaves() == [a])
    #expect(tree.contains(a))
  }

  @Test
  func insertingGrowsTree() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)

    #expect(tree.isSplit)
    #expect(tree.leaves() == [a, b, c])
  }

  @Test
  func insertingAtUnknownAnchorThrows() {
    let a = PaneID(), ghost = PaneID(), b = PaneID()
    let tree = SplitTree(leaf: a)
    #expect(throws: SplitTree<PaneID>.SplitError.leafNotFound) {
      _ = try tree.inserting(b, at: ghost, direction: .right)
    }
  }

  @Test
  func removingCollapsesSingletonSplit() throws {
    let a = PaneID(), b = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    let afterRemoveB = tree.removing(b)
    #expect(afterRemoveB.leaves() == [a])
    #expect(!afterRemoveB.isSplit)
  }

  @Test
  func removingNonExistentLeafIsNoop() {
    let a = PaneID(), ghost = PaneID()
    let tree = SplitTree(leaf: a)
    #expect(tree.removing(ghost) == tree)
  }

  @Test
  func removingOnlyLeafYieldsEmptyTree() {
    let a = PaneID()
    let tree = SplitTree(leaf: a).removing(a)
    #expect(tree.isEmpty)
  }

  @Test
  func replacingSwapsLeafAndPreservesShape() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let original = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    let replaced = try original.replacing(b, with: c)
    #expect(replaced.leaves() == [a, c])
    #expect(replaced.isSplit)
  }

  @Test
  func pathToLeafNavigatesLeftFirst() throws {
    let a = PaneID(), b = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    // `inserting(..., at: a, direction: .right)` places the new leaf to the right, so `a` is on left.
    let pathA = try #require(tree.path(to: a))
    let pathB = try #require(tree.path(to: b))
    #expect(pathA.components == [.left])
    #expect(pathB.components == [.right])
  }

  @Test
  func pathToUnknownLeafReturnsNil() {
    let a = PaneID(), ghost = PaneID()
    let tree = SplitTree(leaf: a)
    #expect(tree.path(to: ghost) == nil)
  }

  @Test
  func focusTargetNextWrapsAround() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .right)
    #expect(tree.focusTarget(for: .next, from: a) == b)
    #expect(tree.focusTarget(for: .next, from: b) == c)
    #expect(tree.focusTarget(for: .next, from: c) == a)
    #expect(tree.focusTarget(for: .previous, from: a) == c)
  }

  @Test
  func focusAfterClosingUsesNextForLeftmost() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .right)
    #expect(tree.focusTargetAfterClosing(a) == b)
    #expect(tree.focusTargetAfterClosing(c) == b)
  }

  @Test
  func focusAfterClosingSingletonReturnsNil() {
    let a = PaneID()
    let tree = SplitTree(leaf: a)
    #expect(tree.focusTargetAfterClosing(a) == nil)
  }

  @Test
  func spatialFocusInTwoPaneRowGoesLeftRightAndNoOpsVertical() throws {
    // Layout: A | B (single horizontal split → A left, B right).
    let a = PaneID(), b = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    #expect(tree.focusTarget(spatial: .right, from: a) == b)
    #expect(tree.focusTarget(spatial: .left, from: b) == a)
    #expect(tree.focusTarget(spatial: .left, from: a) == nil)
    #expect(tree.focusTarget(spatial: .right, from: b) == nil)
    // Vertical directions are no-ops on a single horizontal split.
    #expect(tree.focusTarget(spatial: .up, from: a) == nil)
    #expect(tree.focusTarget(spatial: .down, from: a) == nil)
  }

  @Test
  func spatialFocusInTwoByTwoGridResolvesEveryDirection() throws {
    // Layout (L→R then split each column vertically):
    //   +----+----+
    //   | TL | TR |
    //   +----+----+
    //   | BL | BR |
    //   +----+----+
    let topLeft = PaneID(), topRight = PaneID()
    let bottomLeft = PaneID(), bottomRight = PaneID()
    let tree = try SplitTree(leaf: topLeft)
      .inserting(topRight, at: topLeft, direction: .right)
      .inserting(bottomLeft, at: topLeft, direction: .down)
      .inserting(bottomRight, at: topRight, direction: .down)

    // From TL: right → TR, down → BL, edges are no-op.
    #expect(tree.focusTarget(spatial: .right, from: topLeft) == topRight)
    #expect(tree.focusTarget(spatial: .down, from: topLeft) == bottomLeft)
    #expect(tree.focusTarget(spatial: .left, from: topLeft) == nil)
    #expect(tree.focusTarget(spatial: .up, from: topLeft) == nil)

    // From BR: left → BL, up → TR, edges are no-op.
    #expect(tree.focusTarget(spatial: .left, from: bottomRight) == bottomLeft)
    #expect(tree.focusTarget(spatial: .up, from: bottomRight) == topRight)
    #expect(tree.focusTarget(spatial: .right, from: bottomRight) == nil)
    #expect(tree.focusTarget(spatial: .down, from: bottomRight) == nil)

    // From TR: left → TL (Y-overlap with TR beats BL), down → BR.
    #expect(tree.focusTarget(spatial: .left, from: topRight) == topLeft)
    #expect(tree.focusTarget(spatial: .down, from: topRight) == bottomRight)
  }

  @Test
  func spatialFocusPrefersOverlappingNeighborOverDistantSibling() throws {
    // Build a "tall right column / split left column" layout by
    // splitting only the left leaf vertically:
    //   +----+      +
    //   |topA|      |
    //   +----+ topB |
    //   |bot |      |
    //   +----+------+
    // From topA: right → topB (full Y-overlap with topA's row),
    // down → bot (X-overlap with topA, topB has no overlap on the
    // perpendicular axis when measured from topA's row anyway).
    let topA = PaneID(), topB = PaneID(), bot = PaneID()
    let tree = try SplitTree(leaf: topA)
      .inserting(topB, at: topA, direction: .right)
      .inserting(bot, at: topA, direction: .down)
    #expect(tree.focusTarget(spatial: .right, from: topA) == topB)
    #expect(tree.focusTarget(spatial: .down, from: topA) == bot)
    // From topB the column spans the full height — there is no slot
    // strictly below it, so down is a no-op.
    #expect(tree.focusTarget(spatial: .down, from: topB) == nil)
    // From bot: right reaches topB (Y-ranges overlap), up reaches topA.
    #expect(tree.focusTarget(spatial: .right, from: bot) == topB)
    #expect(tree.focusTarget(spatial: .up, from: bot) == topA)
  }

  @Test
  func spatialFocusOnSingletonReturnsNil() {
    let a = PaneID()
    let tree = SplitTree(leaf: a)
    #expect(tree.focusTarget(spatial: .right, from: a) == nil)
    #expect(tree.focusTarget(spatial: .down, from: a) == nil)
  }

  @Test
  func zoomedLeafTracksReplacementAndRemoval() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .settingZoomed(b)
    #expect(tree.zoomed == b)

    let replaced = try tree.replacing(b, with: c)
    #expect(replaced.zoomed == c)

    let removed = replaced.removing(c)
    #expect(removed.zoomed == nil)
  }

  @Test
  func resizingClampsRatio() throws {
    let a = PaneID(), b = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    let rootPath = SplitTree<PaneID>.Path()
    let clampedHigh = try tree.resizing(at: rootPath, ratio: 1.5)
    let clampedLow = try tree.resizing(at: rootPath, ratio: -0.2)
    guard case .split(let high) = clampedHigh.root else { Issue.record("Expected split"); return }
    guard case .split(let low) = clampedLow.root else { Issue.record("Expected split"); return }
    #expect(high.ratio == 0.9)
    #expect(low.ratio == 0.1)
  }

  @Test
  func codableRoundTripPreservesStructure() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)
      .settingZoomed(b)

    let data = try JSONEncoder().encode(tree)
    let decoded = try JSONDecoder().decode(SplitTree<PaneID>.self, from: data)
    #expect(decoded == tree)
  }

  // MARK: - moving

  @Test
  func movingReparentsAndPreservesLeafSet() throws {
    // Layout: A | (B / C). Move C beside A on the left → C re-parents next to A.
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)

    let moved = try tree.moving(c, relativeTo: a, direction: .left)

    // Leaf *set* is invariant under a move; only the shape changes.
    #expect(Set(moved.leaves()) == Set([a, b, c]))
    // C now sits to the left of A, so its path leads with `.left`.
    let pathC = try #require(moved.path(to: c))
    #expect(pathC.components.first == .left)
  }

  @Test
  func movingInTwoPaneTreeReSplitsInNewDirection() throws {
    // A | B (horizontal). Move B above A → vertical split with B on top.
    let a = PaneID(), b = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)

    let moved = try tree.moving(b, relativeTo: a, direction: .up)

    #expect(Set(moved.leaves()) == Set([a, b]))
    guard case .split(let split) = moved.root else {
      Issue.record("Expected split root")
      return
    }
    #expect(split.direction == .vertical)
    // `.up` puts the moved leaf on the `left` (top) side.
    #expect(split.left == .leaf(b))
    #expect(split.right == .leaf(a))
  }

  @Test
  func movingOntoSelfIsNoop() throws {
    let a = PaneID(), b = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    #expect(try tree.moving(a, relativeTo: a, direction: .down) == tree)
  }

  @Test
  func movingUnknownLeafOrAnchorThrows() throws {
    let a = PaneID(), b = PaneID(), ghost = PaneID()
    let tree = try SplitTree(leaf: a).inserting(b, at: a, direction: .right)
    #expect(throws: SplitTree<PaneID>.SplitError.leafNotFound) {
      _ = try tree.moving(ghost, relativeTo: a, direction: .right)
    }
    #expect(throws: SplitTree<PaneID>.SplitError.leafNotFound) {
      _ = try tree.moving(a, relativeTo: ghost, direction: .right)
    }
  }

  @Test
  func movingZoomedLeafClearsZoom() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)
      .settingZoomed(c)

    let moved = try tree.moving(c, relativeTo: a, direction: .left)
    #expect(moved.zoomed == nil)
  }

  @Test
  func movingNonZoomedLeafKeepsZoom() throws {
    let a = PaneID(), b = PaneID(), c = PaneID()
    let tree = try SplitTree(leaf: a)
      .inserting(b, at: a, direction: .right)
      .inserting(c, at: b, direction: .down)
      .settingZoomed(a)

    let moved = try tree.moving(c, relativeTo: b, direction: .right)
    #expect(moved.zoomed == a)
  }
}
