import Foundation
import Sentry

/// `beforeSend` event scrubber. Drops events whose entire stack is in
/// known system-level noise — typically main-thread blocks during wake
/// from sleep, Mission Control space switches, or external-display
/// reconnect, where AppKit/CGS round-trips to WindowServer can exceed
/// any hang threshold even though the app itself is idle.
///
/// The filter is intentionally conservative: an event is dropped only
/// when *every* stack frame matches a system noise pattern. Any frame
/// pointing into our own code (or any framework other than the listed
/// system ones) lets the event through so a genuine bug is still
/// reported. The pattern list is additive — new false positives get
/// added to `systemNoiseSignatures` and re-shipped.
nonisolated enum SystemHangFilter {
  /// Frame-name substrings that, on their own, indicate macOS / AppKit
  /// internals rather than touch-code code. Matched as case-sensitive
  /// substrings against the frame's `function` field as Sentry sees it.
  static let systemNoiseSignatures: [String] = [
    "mach_msg",
    "mach_msg2_trap",
    "__CFRunLoopRun",
    "__CFRunLoopServiceMachPort",
    "CGSConnectionByID",
    "_CGSGetWindowProperty",
    "NSMenuBarDisplayManager",
    "_NSMenuBarDisplayManagerActiveSpaceChanged",
    "_dispatch_mach_msg_send",
    "xpc_connection_send_message",
  ]

  /// Sentry's `beforeSend` signature. Returns `nil` to drop, the event
  /// itself otherwise. Marked `@Sendable` because Sentry invokes the
  /// closure off the main actor.
  @Sendable
  static func filter(_ event: Event) -> Event? {
    guard let frames = collectFrameFunctions(event), !frames.isEmpty else {
      return event
    }
    let everyFrameIsNoise = frames.allSatisfy { function in
      systemNoiseSignatures.contains { signature in function.contains(signature) }
    }
    return everyFrameIsNoise ? nil : event
  }

  /// Pulls `function` names from every threaded stack frame on the
  /// event. Returns `nil` when there is nothing to inspect (so the
  /// caller forwards the event untouched).
  private static func collectFrameFunctions(_ event: Event) -> [String]? {
    guard let threads = event.threads else { return nil }
    var functions: [String] = []
    for thread in threads {
      guard let stacktrace = thread.stacktrace else { continue }
      for frame in stacktrace.frames {
        if let function = frame.function {
          functions.append(function)
        }
      }
    }
    return functions
  }
}
