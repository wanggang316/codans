import AppKit
import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct GhosttySurfaceViewTests {
  @Test
  func initialSizeSeedsTheFrame() {
    let view = GhosttySurfaceView(contentID: ContentID(), initialSize: CGSize(width: 1_234, height: 567))
    #expect(view.frame.size == CGSize(width: 1_234, height: 567))
  }

  @Test
  func missingInitialSizeFallsBackToThePlaceholder() {
    let view = GhosttySurfaceView(contentID: ContentID(), initialSize: nil)
    #expect(view.frame.size == GhosttySurfaceView.placeholderSize)
  }

  @Test
  func emptyInitialSizeFallsBackToThePlaceholder() {
    let view = GhosttySurfaceView(contentID: ContentID(), initialSize: .zero)
    #expect(view.frame.size == GhosttySurfaceView.placeholderSize)
  }

  @Test
  func initialPixelSizeMatchesTheGeometryPush() {
    let view = GhosttySurfaceView(contentID: ContentID(), initialSize: CGSize(width: 600, height: 400))
    let expected = view.convertToBacking(view.bounds.size)
    let pixels = view.initialPixelSize
    #expect(pixels.width == UInt32(expected.width))
    #expect(pixels.height == UInt32(expected.height))
  }
}
