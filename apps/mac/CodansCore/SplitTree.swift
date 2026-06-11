import CoreGraphics
import Foundation

public nonisolated struct SplitTree<Leaf: Hashable & Codable & Sendable>: Equatable, Codable, Sendable {
  public let root: Node?
  public let zoomed: Leaf?

  public init() { self.init(root: nil, zoomed: nil) }
  public init(leaf: Leaf) { self.init(root: .leaf(leaf), zoomed: nil) }
  public init(root: Node?, zoomed: Leaf? = nil) {
    self.root = root
    self.zoomed = root.flatMap { r in zoomed.flatMap { r.contains($0) ? $0 : nil } }
  }

  public var isEmpty: Bool { root == nil }
  public var isSplit: Bool { if case .split = root { true } else { false } }

  public indirect enum Node: Equatable, Codable, Sendable {
    case leaf(Leaf)
    case split(Split)
  }

  public struct Split: Equatable, Codable, Sendable {
    public let direction: Direction
    public let ratio: Double
    public let left: Node
    public let right: Node

    public init(direction: Direction, ratio: Double, left: Node, right: Node) {
      self.direction = direction
      self.ratio = ratio
      self.left = left
      self.right = right
    }
  }

  public enum Direction: String, Codable, Sendable { case horizontal, vertical }

  public enum NewDirection: String, Codable, Sendable { case left, right, up, down }

  public enum PathComponent: String, Codable, Sendable { case left, right }

  public struct Path: Equatable, Codable, Sendable {
    public let components: [PathComponent]
    public var isEmpty: Bool { components.isEmpty }
    public init(_ components: [PathComponent] = []) { self.components = components }
  }

  public enum FocusDirection: Sendable { case previous, next }

  public enum SplitError: Error, Equatable { case leafNotFound }

  // MARK: - Inspection

  public func leaves() -> [Leaf] { root?.leaves() ?? [] }

  public func contains(_ leaf: Leaf) -> Bool { root?.contains(leaf) ?? false }

  public func path(to leaf: Leaf) -> Path? { root?.path(to: leaf) }

  // MARK: - Mutation

  public func inserting(_ leaf: Leaf, at anchor: Leaf, direction: NewDirection) throws -> Self {
    guard let root else { throw SplitError.leafNotFound }
    guard let path = root.path(to: anchor) else { throw SplitError.leafNotFound }

    let (splitDirection, newOnLeft): (Direction, Bool) =
      switch direction {
      case .left: (.horizontal, true)
      case .right: (.horizontal, false)
      case .up: (.vertical, true)
      case .down: (.vertical, false)
      }

    let newNode: Node = .leaf(leaf)
    let anchorNode: Node = .leaf(anchor)
    let newSplit: Node = .split(
      Split(
        direction: splitDirection,
        ratio: 0.5,
        left: newOnLeft ? newNode : anchorNode,
        right: newOnLeft ? anchorNode : newNode
      ))
    let newRoot = try root.replacing(at: path, with: newSplit)
    return Self(root: newRoot, zoomed: zoomed)
  }

  public func removing(_ leaf: Leaf) -> Self {
    guard let root else { return self }
    let newRoot = root.removing(.leaf(leaf))
    let newZoomed = (zoomed == leaf) ? nil : zoomed
    return Self(root: newRoot, zoomed: newZoomed)
  }

  /// Re-positions an existing `leaf` next to `anchor`, splitting `anchor`
  /// along `direction`. Implemented as remove-then-insert so the leaf set is
  /// preserved — only the tree *shape* changes, which keeps a Tab's
  /// pane-array invariant intact and avoids any surface teardown for the
  /// moved pane (its terminal stays alive across the move).
  ///
  /// A move onto the leaf itself is a no-op. Because `anchor != leaf`, the
  /// anchor always survives the `removing` step (worst case a singleton
  /// split collapses onto it), so the subsequent `inserting` can never fail
  /// on a missing anchor. Zoom on the moved leaf is cleared by `removing`.
  public func moving(_ leaf: Leaf, relativeTo anchor: Leaf, direction: NewDirection) throws -> Self {
    guard leaf != anchor else { return self }
    guard contains(leaf), contains(anchor) else { throw SplitError.leafNotFound }
    return try removing(leaf).inserting(leaf, at: anchor, direction: direction)
  }

  public func replacing(_ old: Leaf, with new: Leaf) throws -> Self {
    guard let root else { throw SplitError.leafNotFound }
    guard let path = root.path(to: old) else { throw SplitError.leafNotFound }
    let newRoot = try root.replacing(at: path, with: .leaf(new))
    let newZoomed: Leaf? = (zoomed == old) ? new : zoomed
    return Self(root: newRoot, zoomed: newZoomed)
  }

  public func settingZoomed(_ leaf: Leaf?) -> Self {
    Self(root: root, zoomed: leaf)
  }

  public func resizing(at path: Path, ratio: Double) throws -> Self {
    guard let root else { throw SplitError.leafNotFound }
    let clamped = max(0.1, min(0.9, ratio))
    guard case .split(let split) = root.node(at: path) else { throw SplitError.leafNotFound }
    let newSplit: Node = .split(
      Split(
        direction: split.direction,
        ratio: clamped,
        left: split.left,
        right: split.right
      ))
    let newRoot = try root.replacing(at: path, with: newSplit)
    return Self(root: newRoot, zoomed: zoomed)
  }

  // MARK: - Focus

  public func focusTarget(for direction: FocusDirection, from leaf: Leaf) -> Leaf? {
    guard let root, root.contains(leaf) else { return nil }
    let all = root.leaves()
    guard let index = all.firstIndex(of: leaf) else { return nil }
    let next: Int =
      switch direction {
      case .previous: (index - 1 + all.count) % all.count
      case .next: (index + 1) % all.count
      }
    return all[next]
  }

  /// Spatial neighbor lookup. Walks the virtual layout (each split's
  /// `direction` + `ratio` carve a unit square recursively) and returns
  /// the nearest leaf strictly on the requested side of `leaf`. Returns
  /// `nil` when `leaf` is on the edge in that direction — callers treat
  /// that as a no-op so the user's mental model "up means up" holds.
  ///
  /// The unit-square layout is sufficient for direction reasoning: only
  /// the relative ordering of `bounds.minX/minY/maxX/maxY` matters, and
  /// those preserve under any positive scaling. No live frame data is
  /// required.
  public func focusTarget(spatial direction: SpatialDirection, from leaf: Leaf) -> Leaf? {
    guard let root, root.contains(leaf) else { return nil }
    let slots = root.spatialLeafSlots(in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let ref = slots.first(where: { $0.leaf == leaf }) else { return nil }
    let candidates: [SpatialSlot] = slots.filter { slot in
      slot.leaf != leaf && slot.matches(direction: direction, relativeTo: ref.bounds)
    }
    guard !candidates.isEmpty else { return nil }
    // Two-step ranking, mirrors typical tiling-WM "directional focus"
    // behavior: prefer slots whose perpendicular extent overlaps the
    // reference (a true neighbor on that side), break ties by Euclidean
    // distance between bounds origins so the closest visible neighbor
    // wins for grids where multiple slots all overlap.
    return candidates.min { lhs, rhs in
      let lOverlap = lhs.perpendicularOverlap(direction: direction, with: ref.bounds)
      let rOverlap = rhs.perpendicularOverlap(direction: direction, with: ref.bounds)
      if lOverlap != rOverlap { return lOverlap > rOverlap }
      return lhs.distance(to: ref.bounds) < rhs.distance(to: ref.bounds)
    }?.leaf
  }

  public func focusTargetAfterClosing(_ leaf: Leaf) -> Leaf? {
    guard let root, root.contains(leaf) else { return nil }
    let all = root.leaves()
    guard all.count > 1 else { return nil }
    // Match Ghostty's controller: closing the leftmost leaf moves to the next; otherwise to the previous.
    if all.first == leaf {
      return focusTarget(for: .next, from: leaf)
    } else {
      return focusTarget(for: .previous, from: leaf)
    }
  }
}

// MARK: - Spatial layout

extension SplitTree {
  public enum SpatialDirection: Sendable, Equatable { case left, right, up, down }

  public struct SpatialSlot: Equatable, Sendable {
    public let leaf: Leaf
    public let bounds: CGRect

    fileprivate func matches(direction: SpatialDirection, relativeTo ref: CGRect) -> Bool {
      switch direction {
      case .left: return bounds.maxX <= ref.minX
      case .right: return bounds.minX >= ref.maxX
      case .up: return bounds.maxY <= ref.minY
      case .down: return bounds.minY >= ref.maxY
      }
    }

    fileprivate func perpendicularOverlap(
      direction: SpatialDirection, with ref: CGRect
    ) -> Double {
      switch direction {
      case .left, .right:
        let lo = max(bounds.minY, ref.minY)
        let hi = min(bounds.maxY, ref.maxY)
        return max(0, hi - lo)
      case .up, .down:
        let lo = max(bounds.minX, ref.minX)
        let hi = min(bounds.maxX, ref.maxX)
        return max(0, hi - lo)
      }
    }

    fileprivate func distance(to ref: CGRect) -> Double {
      let dx = bounds.midX - ref.midX
      let dy = bounds.midY - ref.midY
      return (dx * dx + dy * dy).squareRoot()
    }
  }
}

extension SplitTree.Node {
  fileprivate func spatialLeafSlots(in bounds: CGRect) -> [SplitTree<Leaf>.SpatialSlot] {
    switch self {
    case .leaf(let leaf):
      return [SplitTree<Leaf>.SpatialSlot(leaf: leaf, bounds: bounds)]
    case .split(let split):
      let ratio = max(0, min(1, split.ratio))
      let (leftBounds, rightBounds): (CGRect, CGRect)
      switch split.direction {
      case .horizontal:
        // Vertical seam: left child takes the left fraction of the
        // width; right child takes the remainder. Matches `inserting`
        // semantics where `.right` puts the new pane on the right edge.
        let leftWidth = bounds.width * ratio
        leftBounds = CGRect(
          x: bounds.minX, y: bounds.minY,
          width: leftWidth, height: bounds.height)
        rightBounds = CGRect(
          x: bounds.minX + leftWidth, y: bounds.minY,
          width: bounds.width - leftWidth, height: bounds.height)
      case .vertical:
        // Horizontal seam: left child is on top, right child below.
        // CGRect uses y-down here for ranking; consumers only ever
        // compare relative ordering so the choice of axis is internal.
        let topHeight = bounds.height * ratio
        leftBounds = CGRect(
          x: bounds.minX, y: bounds.minY,
          width: bounds.width, height: topHeight)
        rightBounds = CGRect(
          x: bounds.minX, y: bounds.minY + topHeight,
          width: bounds.width, height: bounds.height - topHeight)
      }
      return split.left.spatialLeafSlots(in: leftBounds)
        + split.right.spatialLeafSlots(in: rightBounds)
    }
  }
}

// MARK: - Node recursion

extension SplitTree.Node {
  public func leaves() -> [Leaf] {
    switch self {
    case .leaf(let leaf): return [leaf]
    case .split(let split): return split.left.leaves() + split.right.leaves()
    }
  }

  public func contains(_ leaf: Leaf) -> Bool {
    switch self {
    case .leaf(let l): return l == leaf
    case .split(let split): return split.left.contains(leaf) || split.right.contains(leaf)
    }
  }

  public func path(to leaf: Leaf) -> SplitTree<Leaf>.Path? {
    var components: [SplitTree<Leaf>.PathComponent] = []
    func search(_ node: SplitTree<Leaf>.Node) -> Bool {
      switch node {
      case .leaf(let l): return l == leaf
      case .split(let split):
        components.append(.left)
        if search(split.left) { return true }
        components.removeLast()
        components.append(.right)
        if search(split.right) { return true }
        components.removeLast()
        return false
      }
    }
    return search(self) ? SplitTree<Leaf>.Path(components) : nil
  }

  public func node(at path: SplitTree<Leaf>.Path) -> SplitTree<Leaf>.Node? {
    if path.isEmpty { return self }
    guard case .split(let split) = self else { return nil }
    let rest = SplitTree<Leaf>.Path(Array(path.components.dropFirst()))
    switch path.components[0] {
    case .left: return split.left.node(at: rest)
    case .right: return split.right.node(at: rest)
    }
  }

  public func replacing(
    at path: SplitTree<Leaf>.Path,
    with newNode: SplitTree<Leaf>.Node
  ) throws -> SplitTree<Leaf>.Node {
    if path.isEmpty { return newNode }
    guard case .split(let split) = self else { throw SplitTree<Leaf>.SplitError.leafNotFound }
    let rest = SplitTree<Leaf>.Path(Array(path.components.dropFirst()))
    switch path.components[0] {
    case .left:
      let newLeft = try split.left.replacing(at: rest, with: newNode)
      return .split(
        SplitTree<Leaf>.Split(
          direction: split.direction, ratio: split.ratio, left: newLeft, right: split.right
        ))
    case .right:
      let newRight = try split.right.replacing(at: rest, with: newNode)
      return .split(
        SplitTree<Leaf>.Split(
          direction: split.direction, ratio: split.ratio, left: split.left, right: newRight
        ))
    }
  }

  public func removing(_ target: SplitTree<Leaf>.Node) -> SplitTree<Leaf>.Node? {
    if self == target { return nil }
    switch self {
    case .leaf:
      return self
    case .split(let split):
      let newLeft = split.left.removing(target)
      let newRight = split.right.removing(target)
      switch (newLeft, newRight) {
      case (nil, nil): return nil
      case (nil, let r?): return r
      case (let l?, nil): return l
      case (let l?, let r?):
        return .split(SplitTree<Leaf>.Split(direction: split.direction, ratio: split.ratio, left: l, right: r))
      }
    }
  }
}
