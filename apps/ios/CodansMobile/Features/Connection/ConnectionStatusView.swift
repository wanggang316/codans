import SwiftUI
import UIKit

/// Placeholder for a list with nothing to show yet: not paired, not
/// connected, or waiting for the first snapshot. Each failure says what
/// fixes it and offers that fix.
struct ConnectionPlaceholderView: View {
  let health: ConnectionHealth
  let retry: () -> Void
  let openSettings: () -> Void

  var body: some View {
    if !health.isPaired {
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
        Label(health.title, systemImage: symbol)
      } description: {
        VStack(spacing: 12) {
          if let explanation = health.explanation {
            Text(explanation)
          }
          if !health.checklist.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(health.checklist, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle")
              }
            }
            .font(.footnote)
          }
        }
      } actions: {
        if let recovery = health.recovery {
          ConnectionRecoveryButton(recovery: recovery, retry: retry, pairAgain: openSettings)
            .buttonStyle(.borderedProminent)
        }
      }
      .accessibilityIdentifier("connection-placeholder")
    }
  }

  private var symbol: String {
    switch health.phase {
    case .failed(let failure):
      switch failure.kind {
      case .localNetworkDenied: return "network.slash"
      case .rejected, .missingKey: return "person.crop.circle.badge.xmark"
      case .incompatible: return "arrow.down.app"
      default: return "exclamationmark.triangle"
      }
    case .discovering where health.isMacMissing, .reconnecting where health.isMacMissing:
      return "desktopcomputer.trianglebadge.exclamationmark"
    default:
      return "antenna.radiowaves.left.and.right"
    }
  }
}

/// The fix a connection failure offers, as a button.
struct ConnectionRecoveryButton: View {
  let recovery: ConnectionHealth.Recovery
  let retry: () -> Void
  let pairAgain: () -> Void

  @Environment(\.openURL) private var openURL

  var body: some View {
    switch recovery {
    case .retry:
      Button("Try Again", action: retry)
        .accessibilityIdentifier("connection-retry")
    case .openSettings:
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
      }
      .accessibilityIdentifier("connection-open-settings")
    case .pairAgain:
      Button("Pair Again", action: pairAgain)
        .accessibilityIdentifier("connection-pair-again")
    }
  }
}

/// Compact connection indicator: a status dot and the status line.
struct ConnectionStatusView: View {
  let health: ConnectionHealth

  var body: some View {
    Label {
      Text(health.title)
    } icon: {
      Image(systemName: "circle.fill")
        .imageScale(.small)
        .foregroundStyle(health.tone.color)
        .accessibilityHidden(true)
    }
  }
}

/// Shown above content that is stale because the connection is not live:
/// what is happening, how old the data is, and the fix when there is one.
struct ConnectionBanner: View {
  let health: ConnectionHealth
  let retry: () -> Void
  let pairAgain: () -> Void

  var body: some View {
    if health.isPaired, !health.isLive {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          ConnectionStatusView(health: health)
            .font(.footnote.weight(.medium))
          if let syncedAt = health.lastSyncedAt {
            TimelineView(.everyMinute) { context in
              Text(Self.updated(syncedAt, now: context.date))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        Spacer(minLength: 8)
        if let recovery = health.recovery {
          ConnectionRecoveryButton(recovery: recovery, retry: retry, pairAgain: pairAgain)
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("connection-banner")
    }
  }

  /// "Updated 3 minutes ago"; "Updated just now" under a minute.
  static func updated(_ date: Date, now: Date) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "Updated just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Updated \(formatter.localizedString(for: date, relativeTo: now))"
  }
}

extension ConnectionHealth.Tone {
  var color: Color {
    switch self {
    case .good: return .green
    case .working: return .orange
    case .idle: return .secondary
    case .bad: return .red
    }
  }
}
