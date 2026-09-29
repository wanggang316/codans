import CodansCore
import SwiftUI

/// Status-slot form for running work: the most recent activity's
/// `Title | detail` followed by its progress ring, which carries the number
/// of running activities when there is more than one. Clicking opens a list
/// of every activity, where cancellable ones offer Stop.
struct StatusActivityView: View {
  let activities: [StatusActivity]
  /// Drops the text when true, keeping only the ring. Driven by
  /// `ViewThatFits` in narrow titlebars.
  var compact: Bool = false
  let onCancel: (StatusActivityID) -> Void

  @State private var isPresented = false
  /// Rows the popover reserves, fixed at open so activities ending while it
  /// is shown never resize the NSPopover (animated resizes have crashed).
  @State private var visibleRows = 1

  var body: some View {
    if let primary = activities.last {
      Button {
        visibleRows = min(max(activities.count, 1), StatusActivityListView.maxVisibleRows)
        isPresented.toggle()
      } label: {
        HStack(spacing: 8) {
          if !compact {
            Text(primary.summary)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          StatusActivityRing(progress: primary.progress, count: activities.count)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(activities.count > 1 ? "\(activities.count) activities running" : primary.summary)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(activities.count > 1 ? "\(activities.count) activities running" : "Activity")
      .accessibilityValue(primary.summary)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Shows running activities")
      .accessibilityIdentifier("status.activity")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        StatusActivityListView(activities: activities, visibleRows: visibleRows, onCancel: onCancel)
          .onExitCommand { isPresented = false }
      }
    }
  }
}

struct StatusActivityListView: View {
  static let maxVisibleRows = 6
  static let rowHeight: CGFloat = 44

  let activities: [StatusActivity]
  let visibleRows: Int
  let onCancel: (StatusActivityID) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        // Most recent first, matching the slot.
        ForEach(activities.reversed()) { activity in
          StatusActivityRow(activity: activity) { onCancel(activity.id) }
        }
      }
    }
    .frame(height: CGFloat(visibleRows) * Self.rowHeight)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(width: 320)
    .transaction { $0.animation = nil }
    .accessibilityIdentifier("status.activity.popover")
  }
}

private struct StatusActivityRow: View {
  let activity: StatusActivity
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      StatusActivityRing(progress: activity.progress, diameter: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(activity.title)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.middle)
        if let detail = activity.detailText {
          Text(detail)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if activity.isCancellable {
        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Stop")
        .accessibilityLabel("Stop \(activity.title)")
      }
    }
    .padding(.horizontal, 4)
    .frame(height: StatusActivityListView.rowHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(activity.summary)
    .accessibilityIdentifier("status.activity.row.\(activity.id)")
  }
}
