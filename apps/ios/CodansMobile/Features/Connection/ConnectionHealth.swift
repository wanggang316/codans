import Foundation

/// What the UI shows about the connection, derived from
/// `ConnectionFeature.State` in one place so every status line, banner and
/// placeholder tells the same story.
struct ConnectionHealth: Equatable {
  enum Recovery: Equatable {
    /// Try again now instead of waiting for the next attempt.
    case retry
    /// Local Network access is off: only iOS Settings can fix it.
    case openSettings
    /// The Mac no longer accepts this device.
    case pairAgain
  }

  var phase: ConnectionFeature.Phase
  /// Nil when no Mac is paired.
  var macName: String?
  /// The last frame of any kind from the Mac.
  var lastContact: Date?
  /// When the shown data last matched the Mac.
  var lastSyncedAt: Date?
  /// Why the connection is not live; nil while live.
  var failure: RemoteFailure?
  /// The reconnect attempt being waited for, while reconnecting.
  var attempt: Int?
  var nextAttemptAt: Date?
  var canRetryNow: Bool
  /// Connected to a Mac too old for the live terminal (protocol minor 1):
  /// browsing and the text fallback work, the terminal asks for an update.
  var needsMacUpdate: Bool
  /// The live session runs through the relay rather than the LAN.
  var isRelayed = false
  /// The pairing knows the Mac's relay, so "not found on this network" is
  /// not the end of the search.
  var hasRelay = false

  var isPaired: Bool { macName != nil }
  var isLive: Bool { phase == .live }

  /// Showing data from before the connection dropped, or from the cache.
  var isStale: Bool { !isLive && lastSyncedAt != nil }

  var recovery: Recovery? {
    if case .failed(let failure) = phase {
      switch failure.kind {
      case .localNetworkDenied: return .openSettings
      case .rejected, .missingKey: return .pairAgain
      default: return .retry
      }
    }
    return canRetryNow ? .retry : nil
  }

  private var name: String { macName ?? "your Mac" }

  /// The last attempt could not find the Mac on this network.
  var isMacMissing: Bool { failure?.kind == .macNotFound }

  /// One short line: the status dot's label.
  var title: String {
    switch phase {
    case .idle: return isPaired ? "Not connected" : "Not paired"
    // While retrying after "not found", the title stays on the cause
    // instead of flickering between it and "Looking for…" every attempt.
    case .discovering where isMacMissing, .reconnecting where isMacMissing: return "Can't find \(name)"
    case .discovering: return "Looking for \(name)…"
    case .handshaking: return "Connecting to \(name)…"
    case .syncing: return "Syncing with \(name)…"
    case .live: return isRelayed ? "Connected to \(name) via relay" : "Connected to \(name)"
    case .reconnecting(let attempt, _): return "Reconnecting (attempt \(attempt))"
    case .offline: return "Offline"
    case .failed(let failure):
      switch failure.kind {
      case .localNetworkDenied: return "Local Network access is off"
      case .rejected: return "This device was removed"
      case .incompatible: return "Update needed"
      case .missingKey: return "Pairing key missing"
      default: return "Can't connect"
      }
    }
  }

  /// What went wrong and what fixes it, for placeholders and Settings.
  var explanation: String? {
    if case .failed(let failure) = phase, failure.kind == .rejected {
      return
        "\(name) no longer accepts this device: it was removed in Codans Settings › Remote Access, or its pairing expired. Pair again to reconnect."
    }
    guard let failure else { return nil }
    return phase.isConnecting ? "\(failure.message) Trying again…" : failure.message
  }

  /// The usual reasons a paired Mac cannot be found, as a checklist.
  var checklist: [String] {
    guard failure?.kind == .macNotFound else { return [] }
    if hasRelay {
      return [
        "\(macName ?? "Your Mac") is awake and online",
        "Codans is running with Remote Access on",
        "Access from outside this network is allowed in Remote Access",
      ]
    }
    return [
      "\(macName ?? "Your Mac") is awake",
      "Codans is running with Remote Access on",
      "Both devices are on the same network",
    ]
  }

  /// The status line under the Mac's name: short, since the name is
  /// already above it. The age of stale data is appended by the view,
  /// which ticks it.
  var shortStatus: String {
    switch phase {
    case .idle: return isPaired ? "Not connected" : "Not paired"
    case .discovering where isMacMissing, .reconnecting where isMacMissing: return "Can't find Mac"
    case .discovering: return "Looking for Mac…"
    case .handshaking: return "Connecting…"
    case .syncing: return "Syncing…"
    case .live: return isRelayed ? "Connected via relay" : "Connected"
    // The banner under the bar carries the attempt and countdown.
    case .reconnecting: return "Reconnecting…"
    case .offline: return "Offline"
    case .failed(let failure):
      switch failure.kind {
      case .localNetworkDenied: return "Local Network off"
      case .rejected: return "Removed from Mac"
      case .incompatible: return "Update needed"
      case .missingKey: return "Pairing key missing"
      default: return "Can't connect"
      }
    }
  }

  /// A state that takes the whole page instead of the workspace: nothing
  /// can be shown, or what is shown can never refresh until the user acts.
  enum Blocker: Equatable {
    case notPaired
    case macNotFound
    case localNetworkDenied
    case rejected
    case missingKey
    case incompatible
    case failed
  }

  /// Nil when the workspace (live, stale or loading) should show, with the
  /// connection state in its status line and banner.
  func blocker(hasContent: Bool) -> Blocker? {
    guard isPaired else { return .notPaired }
    if case .failed(let failure) = phase {
      switch failure.kind {
      case .localNetworkDenied: return .localNetworkDenied
      case .rejected: return .rejected
      case .missingKey: return .missingKey
      case .incompatible: return .incompatible
      default: return hasContent ? nil : .failed
      }
    }
    // Cached content beats a checklist: the user can still look around
    // while the Mac is being looked for.
    return isMacMissing && !hasContent ? .macNotFound : nil
  }

  enum Tone: Equatable {
    case good
    case working
    case idle
    case bad
  }

  var tone: Tone {
    switch phase {
    case .live: return .good
    case .discovering, .handshaking, .syncing, .reconnecting: return .working
    case .idle, .offline: return .idle
    case .failed: return .bad
    }
  }
}
