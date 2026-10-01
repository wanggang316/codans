import CodansCore
import Foundation
import Observation

/// Panes a paired device has sized for itself, as the Mac shows them.
///
/// While a device leads a pane (D61), the pane's PTY takes the device's
/// grid and the Mac's surface draws that smaller grid in its top-left
/// corner over stale cells. `TerminalStreamRegistry` records each such
/// pane here so the pane can cover the unused cells and offer the size
/// back.
@MainActor
@Observable
final class RemotePaneSizing {
  struct Sizing: Equatable {
    /// The paired device's name, when known.
    var deviceName: String?
    /// The PTY's grid, which is the device's.
    var cols: Int
    var rows: Int
    /// The grid the Mac's surface lays out.
    var macCols: Int
    var macRows: Int
  }

  private(set) var panes: [PaneID: Sizing] = [:]
  /// Hands the pane's size back to the Mac.
  @ObservationIgnored var takeBack: @MainActor (PaneID) -> Void = { _ in }

  func set(_ sizing: Sizing?, for paneID: PaneID) {
    guard panes[paneID] != sizing else { return }
    panes[paneID] = sizing
  }
}
