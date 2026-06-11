import Foundation
import OSLog

/// Forensic log trail for the appearance dual-path (SwiftUI + AppKit) and Ghostty scheme
/// sync. Single-line `os_log` records let us ask a user for a Console dump when they
/// report "one window didn't update" or "Ghostty didn't switch palette." Each call site
/// passes a plain-text event with `key=value` fields so entries grep cleanly.
enum AppearanceDiagnostics {
  private static let logger = Logger(subsystem: "com.gumpw.codans.mac", category: "appearance")

  static func log(_ message: String) {
    logger.log("\(message, privacy: .public)")
  }
}
