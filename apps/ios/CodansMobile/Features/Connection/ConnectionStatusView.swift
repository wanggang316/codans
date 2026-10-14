import SwiftUI
import UIKit

/// The status line under the Mac's name: a dot and "Connected",
/// "Syncing…", "Reconnecting… · 2 min ago" or "Offline · 3 min ago".
struct ConnectionStatusLine: View {
  let health: ConnectionHealth

  var body: some View {
    TimelineView(.everyMinute) { context in
      HStack(spacing: 6) {
        StatusDot(color: health.tone.color, pulses: health.tone == .working, size: 7)
        Text(text(now: context.date))
          .lineLimit(1)
      }
    }
    .foregroundStyle(Color.inkSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("connection-status")
  }

  private func text(now: Date) -> String {
    guard health.isStale, !health.phase.isConnecting, let syncedAt = health.lastSyncedAt else {
      return health.shortStatus
    }
    return "\(health.shortStatus) · \(StaleBadge.age(syncedAt, now: now))"
  }
}

/// The reconnecting strip over stale content: what the connection is doing,
/// the attempt and countdown, how old the data is, and "Retry now". The
/// content under it stays usable.
struct ConnectionBanner: View {
  let health: ConnectionHealth
  let retry: () -> Void
  let pairAgain: () -> Void

  var body: some View {
    if health.isPaired, !health.isLive {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        InlineBanner(
          color: health.tone.color,
          pulses: health.tone == .working,
          title: title,
          detail: { Text(detail(now: context.date)).monospacedDigit() },
          actionTitle: actionTitle,
          action: action
        )
      }
      .accessibilityIdentifier("connection-banner")
    }
  }

  private var name: String { health.macName ?? "your Mac" }

  private var title: String {
    switch health.phase {
    case .discovering where health.isMacMissing, .reconnecting where health.isMacMissing:
      return "Can't find \(name)"
    case .reconnecting: return "Reconnecting to \(name)…"
    case .discovering: return "Looking for \(name)…"
    case .handshaking: return "Connecting to \(name)…"
    case .syncing: return "Syncing with \(name)…"
    case .offline: return "Offline"
    case .idle, .live, .failed: return health.title
    }
  }

  private func detail(now: Date) -> String {
    var parts: [String] = []
    if case .reconnecting(let attempt, let at) = health.phase {
      // The data's age is on the status line above; one line here keeps
      // the countdown from wrapping.
      let seconds = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
      return seconds > 0 ? "Attempt \(attempt) · retry in \(seconds)s" : "Attempt \(attempt) · retrying…"
    } else if case .failed = health.phase, let explanation = health.explanation {
      parts.append(explanation)
    }
    if let syncedAt = health.lastSyncedAt {
      parts.append(StaleBadge.text(syncedAt, now: now))
    }
    return parts.joined(separator: " · ")
  }

  private var actionTitle: String? {
    switch health.recovery {
    case .retry?: return "Retry now"
    case .openSettings?: return "Settings"
    case .pairAgain?: return "Pair again"
    case nil: return nil
    }
  }

  @Environment(\.openURL) private var openURL

  private var action: (() -> Void)? {
    switch health.recovery {
    case .retry?: return retry
    case .pairAgain?: return pairAgain
    case .openSettings?:
      return {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
      }
    case nil: return nil
    }
  }

  /// "Updated 3 min ago"; "Updated just now" under a minute.
  static func updated(_ date: Date, now: Date) -> String {
    StaleBadge.text(date, now: now)
  }
}

/// A full page for a connection state with nothing else to show, or where
/// nothing shown could refresh until the user acts: not paired, the Mac not
/// found, Local Network denied, removed from the Mac, an update needed.
struct ConnectionStateView: View {
  let blocker: ConnectionHealth.Blocker
  let health: ConnectionHealth
  let retry: () -> Void
  let pair: () -> Void

  @Environment(\.openURL) private var openURL

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      state(now: context.date)
    }
    .accessibilityIdentifier("connection-placeholder")
  }

  private var name: String { health.macName ?? "your Mac" }
  private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

  private func state(now: Date) -> StateView {
    switch blocker {
    case .notPaired:
      return StateView(
        symbol: "macbook.and.iphone",
        title: "Pair with your Mac",
        message: "Codans on your Mac shows a pairing code in Settings › Remote Access › Pair New Device.",
        primary: .init("Pair", identifier: "connection-pair", perform: pair))
    case .macNotFound:
      return StateView(
        symbol: "desktopcomputer",
        title: "Can't find \(name)",
        message: "Codans keeps looking. Check that:",
        checklist: [
          "\(health.macName ?? "Your Mac") is awake",
          "Remote Access is on in Codans Settings",
          "This \(device) is on the same Wi‑Fi",
        ],
        status: countdown(now: now),
        primary: .init("Retry", identifier: "connection-retry", perform: retry))
    case .localNetworkDenied:
      return StateView(
        symbol: "network.slash",
        title: "Allow Local Network",
        message: "Codans reaches your Mac over your local network, and iOS has that turned off for it.",
        checklist: ["Open Settings › Apps › Codans", "Turn on Local Network"],
        primary: .init("Open Settings", identifier: "connection-open-settings") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        })
    case .rejected:
      return StateView(
        symbol: "iphone.slash",
        tint: .failure,
        title: "This \(device) was removed from \(name)",
        message: "It was removed in Codans Settings › Remote Access, or its pairing expired.",
        primary: .init("Pair again", identifier: "connection-pair-again", perform: pair),
        secondary: .init("Try again", identifier: "connection-retry", perform: retry))
    case .missingKey:
      return StateView(
        symbol: "key.slash",
        tint: .failure,
        title: "Pairing key missing",
        message: "This \(device) no longer has the key it shares with \(name). Pair again to reconnect.",
        primary: .init("Pair again", identifier: "connection-pair-again", perform: pair))
    case .incompatible:
      return StateView(
        symbol: "arrow.down.app",
        title: "Update Codans on your Mac",
        message: "\(name) runs a version of Codans this app can't talk to. Update it, then try again.",
        primary: .init("Try again", identifier: "connection-retry", perform: retry))
    case .failed:
      return StateView(
        symbol: "exclamationmark.triangle",
        tint: .failure,
        title: health.title,
        message: health.explanation,
        primary: .init("Try again", identifier: "connection-retry", perform: retry))
    }
  }

  private func countdown(now: Date) -> String? {
    if health.phase.isConnecting { return "Looking now…" }
    guard case .reconnecting(let attempt, let at) = health.phase else { return nil }
    let seconds = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
    return seconds > 0 ? "Attempt \(attempt) · next try in \(seconds)s" : "Looking now…"
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
      Button("Reconnect Now", action: retry)
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

extension ConnectionHealth.Tone {
  var color: Color {
    switch self {
    case .good: return .working
    // Grey and pulsing: amber is taken by "an agent needs you".
    case .working: return .offline
    case .idle: return .offline
    case .bad: return .failure
    }
  }
}
