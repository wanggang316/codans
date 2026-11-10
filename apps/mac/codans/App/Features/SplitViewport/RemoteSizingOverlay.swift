import CodansCore
import SwiftUI

/// Shown over a pane while a paired device has it at the device's size.
///
/// The PTY then has the device's grid, which the Mac's surface draws in
/// its top-left corner; the cells beyond it hold whatever was there
/// before. The overlay frosts those cells and says why, with a button
/// that hands the size back. Typing in the pane does the same, so clicks
/// on the frosted cells go through to the terminal.
struct RemoteSizingOverlay: View {
  let paneID: PaneID
  @Environment(RemotePaneSizing.self) private var sizing: RemotePaneSizing?

  var body: some View {
    let info = sizing?.panes[paneID]
    ZStack {
      if let info {
        GeometryReader { proxy in
          ZStack(alignment: .bottomTrailing) {
            UnusedCells(used: usedRect(info, in: proxy.size))
              .fill(.regularMaterial, style: FillStyle(eoFill: true))
              .allowsHitTesting(false)
            notice(info)
              .padding(12)
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: info)
  }

  /// The cells the device's grid covers, measured in the Mac's cells.
  private func usedRect(_ info: RemotePaneSizing.Sizing, in size: CGSize) -> CGRect {
    let cellWidth = size.width / CGFloat(max(info.macCols, 1))
    let cellHeight = size.height / CGFloat(max(info.macRows, 1))
    return CGRect(
      x: 0, y: 0,
      width: min(size.width, cellWidth * CGFloat(info.cols)),
      height: min(size.height, cellHeight * CGFloat(info.rows)))
  }

  private func notice(_ info: RemotePaneSizing.Sizing) -> some View {
    let name = info.deviceName ?? "a paired device"
    let symbol = name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    return HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("Sized for \(name)")
          .font(.callout.weight(.medium))
        Text("\(info.cols)×\(info.rows) · type here to take it back")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Button("Use Mac Size") { sizing?.takeBack(paneID) }
        .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.separator, lineWidth: 0.5)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("remote-sizing-notice")
  }
}

/// The pane minus the device's cells.
nonisolated private struct UnusedCells: Shape {
  let used: CGRect

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.addRect(rect)
    path.addRect(used)
    return path
  }
}
