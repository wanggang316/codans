import CoreGraphics
import Foundation

/// Whether someone is at this Mac, for deciding when a remote device may
/// take a pane's size without typing first (`TerminalSizeClaim.auto`).
///
/// Away means the screen is locked or there has been no keyboard, mouse or
/// trackpad input for `idleThreshold`: then resizing a pane for a phone
/// disturbs nobody. At the Mac, the phone waits until its user types.
nonisolated enum MacPresence {
  static let idleThreshold: TimeInterval = 60

  static func isAway() -> Bool {
    isScreenLocked() || secondsSinceLastInput() >= idleThreshold
  }

  static func secondsSinceLastInput() -> TimeInterval {
    // `kCGAnyInputEventType`: imported C enums take any raw value.
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }

  static func isScreenLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
  }
}
