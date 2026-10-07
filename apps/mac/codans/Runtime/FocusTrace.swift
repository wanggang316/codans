import AppKit
import OSLog

/// Persisted record of who moves keyboard focus into a terminal surface.
///
/// Focus bugs here are intermittent and do not reproduce on demand (typing
/// that lands in a pane behind the open Command Palette, the IME badge that
/// flickers in and out). Each record names the claim path and the responder
/// it replaced, and carries the caller's return addresses with the image load
/// address so a release stack can be symbolicated afterwards:
///
///     log show --last 1d --predicate 'subsystem == "com.gumpw.codans.runtime" AND category == "focus"'
///     atos -o Codans.app.dSYM/Contents/Resources/DWARF/Codans -l <image> <frames…>
///
/// Records are written only for focus changes, so the volume follows user
/// activity.
@MainActor
enum FocusTrace {
  private static let logger = Logger(subsystem: "com.gumpw.codans.runtime", category: "focus")

  static func record(_ event: String, responder: NSResponder?) {
    let frames = Thread.callStackReturnAddresses.dropFirst().prefix(16)
      .map { String(format: "0x%llx", $0.uint64Value) }
      .joined(separator: " ")
    let image = String(format: "0x%llx", UInt64(UInt(bitPattern: #dsohandle)))
    logger.notice(
      "\(event, privacy: .public) responder=\(describe(responder), privacy: .public) image=\(image, privacy: .public) frames=\(frames, privacy: .public)"
    )
  }

  static func describe(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    if let surface = responder as? GhosttySurfaceView { return "surface(\(surface.paneID))" }
    return String(describing: type(of: responder))
  }
}
