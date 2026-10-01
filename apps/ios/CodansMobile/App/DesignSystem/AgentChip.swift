import SwiftUI

/// An agent's state as a tinted capsule: "Needs input", "Working",
/// "Idle", with a count when several agents share it.
struct AgentChip: View {
  let kind: AgentGroup.Kind
  var count = 1

  var body: some View {
    HStack(spacing: 5) {
      StatusDot(color: kind.color, pulses: kind == .working, size: 6)
      Text(count > 1 ? "\(kind.shortTitle) · \(count)" : kind.shortTitle)
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
    }
    .foregroundStyle(kind == .idle ? Color.inkSecondary : kind.color)
    .padding(.horizontal, 7)
    .padding(.vertical, 2.5)
    .background(kind.color.opacity(kind == .idle ? 0.12 : 0.14), in: .capsule)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(count > 1 ? "\(count) agents \(kind.title)" : "Agent \(kind.title)")
  }
}

extension AgentGroup.Kind {
  var color: Color {
    switch self {
    case .needsInput: return .needsInput
    case .working: return .working
    case .idle: return .offline
    }
  }

  var shortTitle: String {
    switch self {
    case .needsInput: return "Needs input"
    case .working: return "Working"
    case .idle: return "Idle"
    }
  }
}

/// How old the shown data is, while it is not live: "Updated 3 min ago".
struct StaleBadge: View {
  let since: Date

  var body: some View {
    TimelineView(.everyMinute) { context in
      Label {
        Text(Self.text(since, now: context.date))
      } icon: {
        Image(systemName: "clock")
          .accessibilityHidden(true)
      }
      .labelStyle(StaleBadgeLabelStyle())
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Color.inkSecondary)
    .padding(.horizontal, 7)
    .padding(.vertical, 2.5)
    .background(Color.surfaceMuted, in: .capsule)
    .fixedSize()
    .accessibilityIdentifier("stale-badge")
  }

  /// "Updated just now" under a minute, else "Updated 3 min ago".
  static func text(_ date: Date, now: Date) -> String {
    "Updated \(age(date, now: now))"
  }

  /// "just now", "3 min ago", "2 hr ago".
  static func age(_ date: Date, now: Date) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }
}

private struct StaleBadgeLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}
