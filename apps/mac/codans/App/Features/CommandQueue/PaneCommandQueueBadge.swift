import CodansCore
import SwiftUI

/// Shared vocabulary for the queue affordances — the badge, the panel header,
/// and the per-entry timing line all render through here so a queued command
/// reads the same wherever it appears.
enum CommandQueueBadgeStyle {
  /// SF Symbol for "there is deferred work parked here".
  static let symbol = "text.append"

  /// One breath. Slow enough to read as "waiting", not as "error".
  static let breathDuration: Double = 1.2
  static let dimOpacity: Double = 0.45

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

/// Count pip the pane's actions button wears while the pane holds queued
/// commands. It breathes so a parked queue reads as "waiting" rather than as
/// a static number, and it is not itself a control: the button under it
/// opens the pane menu, whose Command Queue row opens the sheet.
struct PaneCommandQueueBadge: View {
  let count: Int
  /// Drives the breathing loop. Flipped once on appear; the repeating
  /// animation attached to it runs for as long as the pip is mounted.
  @State private var breathing = false

  var body: some View {
    Text("\(count)")
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(.white)
      .padding(.horizontal, 4)
      .frame(minWidth: 15, minHeight: 15)
      .background(Capsule(style: .continuous).fill(Color.accentColor))
      // Breathing loop: `breathing` flips exactly once, on appear, and the
      // autoreversing repeat attached to that single change oscillates the
      // pip for as long as it is mounted. Driving it from one state flip
      // (rather than a timer) keeps it free of a retained ticker.
      .opacity(breathing ? 1 : CommandQueueBadgeStyle.dimOpacity)
      .animation(
        .easeInOut(duration: CommandQueueBadgeStyle.breathDuration)
          .repeatForever(autoreverses: true),
        value: breathing
      )
      .onAppear { breathing = true }
      .allowsHitTesting(false)
      // The button's accessibility label carries the count.
      .accessibilityHidden(true)
  }
}
