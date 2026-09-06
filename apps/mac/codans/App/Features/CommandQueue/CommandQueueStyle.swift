import CodansCore
import SwiftUI

/// Shared vocabulary for the queue affordances — the pane's queue button,
/// the sheet's rows and the per-entry timing line all render through here so
/// a queued command reads the same wherever it appears.
enum CommandQueueStyle {
  /// SF Symbol for "there is deferred work parked here".
  static let symbol = "text.append"

  static func description(of timing: QueuedCommandTiming) -> String {
    switch timing {
    case .afterCurrentTask:
      return "After current task"
    case .scheduled(let date, let interval):
      let when = Self.timestamp(date)
      guard let interval, interval > 0 else { return "At \(when)" }
      return "At \(when) · every \(Self.humanInterval(interval))"
    }
  }

  /// Time-only for today, date + time otherwise — a schedule two days out
  /// must not read as "14:32" and look imminent.
  static func timestamp(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(date: .abbreviated, time: .shortened)
  }

  static func humanInterval(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total >= 3600, total % 3600 == 0 { return "\(total / 3600) h" }
    if total >= 60, total % 60 == 0 { return "\(total / 60) min" }
    return "\(total) s"
  }
}
