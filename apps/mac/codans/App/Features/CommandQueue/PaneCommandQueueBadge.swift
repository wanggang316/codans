import CodansCore
import SwiftUI

/// Shared vocabulary for the queue affordances — the badge, the panel header,
/// and the per-entry timing line all render through here so a queued command
/// reads the same wherever it appears.
enum CommandQueueBadgeStyle {
  /// SF Symbol for "there is deferred work parked here".
  static let symbol = "text.line.first.and.arrowtriangle.forward"

  /// One breath. Slow enough to read as "waiting", not as "error".
  static let breathDuration: Double = 1.2
  static let dimOpacity: Double = 0.45
  static let dimScale: CGFloat = 0.92

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

/// Breathing badge shown beside a pane's actions button while that pane owes
/// the user queued commands. Click opens the same sheet ⌘⌥L summons.
///
/// `PaneHUDView` owns the pane's top-right corner and places this in its
/// collapsed row, so the badge carries no corner inset of its own and reaches
/// the root store through the HUD's `paneHUDActions` seam.
///
/// Renders nothing at all for a pane with an empty queue — the terminal's
/// corner belongs to the terminal unless there is something to say.
struct PaneCommandQueueBadge: View {
  let paneID: PaneID

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.paneHUDActions) private var actions
  @State private var isHovering = false
  /// Drives the breathing loop. Flipped once on appear; the repeating
  /// animation attached to it runs for as long as the badge is mounted.
  @State private var breathing = false

  var body: some View {
    let queue = hierarchyManager.catalog.pane(paneID)?.commandQueue ?? []
    if !queue.isEmpty {
      Button {
        actions.commandQueue(paneID)
      } label: {
        HStack(spacing: 4) {
          Image(systemName: CommandQueueBadgeStyle.symbol)
            .font(.system(size: 10, weight: .semibold))
            .accessibilityHidden(true)
          Text("\(queue.count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
          Capsule(style: .continuous)
            .fill(Color.accentColor.opacity(isHovering ? 0.32 : 0.22))
        }
        .overlay {
          Capsule(style: .continuous)
            .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
        }
        .foregroundStyle(Color.accentColor)
        // Breathing loop: `breathing` flips exactly once, on appear, and the
        // autoreversing repeat attached to that single change oscillates the
        // badge for as long as it is mounted. Driving it from one state flip
        // (rather than a timer) keeps it free of a retained ticker.
        .opacity(breathing ? 1 : CommandQueueBadgeStyle.dimOpacity)
        .scaleEffect(breathing ? 1 : CommandQueueBadgeStyle.dimScale)
        .animation(
          .easeInOut(duration: CommandQueueBadgeStyle.breathDuration)
            .repeatForever(autoreverses: true),
          value: breathing
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }
      .onAppear { breathing = true }
      .help(helpText(queue))
      .accessibilityLabel("Command queue, \(queue.count) pending")
    }
  }

  private func helpText(_ queue: [QueuedCommand]) -> String {
    let head = queue.prefix(3).map { entry in
      "• \(entry.text) — \(CommandQueueBadgeStyle.description(of: entry.timing))"
    }
    let more = queue.count > 3 ? ["… and \(queue.count - 3) more"] : []
    return (head + more).joined(separator: "\n")
  }
}
