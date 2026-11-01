import CodansCore
import Foundation

/// One live pane surface as the reclaim sweep sees it.
nonisolated struct ReclaimableSurface: Equatable, Sendable {
  var paneID: PaneID
  var isDisplayed: Bool
  var isReady: Bool
}

/// The live surfaces the reclaim sweep reads and detaches. `GhosttyRuntime`
/// in the app; headless tests, which cannot create a surface, use a fake.
@MainActor
protocol ReclaimableSurfaceHost: AnyObject {
  func reclaimableSurfaces() -> [ReclaimableSurface]
  /// Close and unregister the pane's surface but keep its zmx daemon.
  /// Returns the surface view's size, or nil when the pane has no surface.
  func detachSurface(for paneID: PaneID) -> CGSize?
}

extension GhosttyRuntime: ReclaimableSurfaceHost {
  func reclaimableSurfaces() -> [ReclaimableSurface] {
    allLiveSurfaces().map {
      ReclaimableSurface(paneID: $0.paneID, isDisplayed: $0.isDisplayed, isReady: $0.state == .ready)
    }
  }

  func detachSurface(for paneID: PaneID) -> CGSize? {
    guard let surface = surface(for: paneID) else { return nil }
    // Detaching ends the `zmx attach` child; make sure that cannot surface
    // as a pane exit.
    surface.onClose = nil
    let size = surface.view.bounds.size
    surface.close()
    unregister(paneID: paneID)
    return size
  }
}
