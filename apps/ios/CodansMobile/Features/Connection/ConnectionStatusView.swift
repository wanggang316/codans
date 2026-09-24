import ComposableArchitecture
import SwiftUI

/// Placeholder for a list with nothing to show yet: not paired, not
/// connected, or waiting for the first snapshot.
struct ConnectionPlaceholderView: View {
  let connection: ConnectionFeature.State
  let openSettings: () -> Void

  var body: some View {
    if connection.activeGateway == nil {
      ContentUnavailableView {
        Label("Pair with Your Mac", systemImage: "macbook.and.iphone")
      } description: {
        Text("On your Mac, open Codans Settings › Remote Access and choose Pair New Device.")
      } actions: {
        Button("Pair", action: openSettings)
          .buttonStyle(.borderedProminent)
      }
    } else {
      ContentUnavailableView {
        Label(ConnectionStatusView.title(for: connection), systemImage: "antenna.radiowaves.left.and.right")
      } description: {
        if let failure = connection.lastFailure {
          Text(failure.message)
        }
      }
    }
  }
}

/// Compact connection indicator for toolbars and banners.
struct ConnectionStatusView: View {
  let connection: ConnectionFeature.State

  var body: some View {
    Label(Self.title(for: connection), systemImage: symbol)
      .foregroundStyle(tint)
  }

  static func title(for connection: ConnectionFeature.State) -> String {
    let name = connection.activeGateway?.displayName ?? "your Mac"
    switch connection.status {
    case .idle:
      return connection.activeGateway == nil ? "Not paired" : "Not connected"
    case .connecting:
      return "Connecting to \(name)…"
    case .connected:
      return "Connected to \(name)"
    case .retrying:
      return "Reconnecting to \(name)…"
    case .suspended:
      return "Paused"
    }
  }

  private var symbol: String {
    switch connection.status {
    case .connected: return "checkmark.circle.fill"
    case .connecting, .retrying: return "arrow.triangle.2.circlepath"
    case .idle, .suspended: return "exclamationmark.circle"
    }
  }

  private var tint: Color {
    switch connection.status {
    case .connected: return .green
    case .connecting, .retrying: return .orange
    case .idle, .suspended: return .secondary
    }
  }
}

/// Shown above content that is stale because the connection dropped.
struct ConnectionBanner: View {
  let connection: ConnectionFeature.State

  var body: some View {
    if connection.activeGateway != nil, connection.status != .connected {
      ConnectionStatusView(connection: connection)
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.bar)
    }
  }
}
