import Foundation

/// Pixel geometry of the slot a Content is shown in. Passed at creation so
/// a terminal surface spawns at the size it will be displayed at — a live
/// session must not be resized through a placeholder width — and on every
/// mount so a re-attached surface starts at its slot size.
nonisolated struct ContentGeometry: Equatable, Sendable {
  /// Size in points.
  var size: CGSize
  /// Backing scale factor of the window the slot lives in.
  var scale: CGFloat

  init(size: CGSize, scale: CGFloat = 1) {
    self.size = size
    self.scale = scale
  }
}
