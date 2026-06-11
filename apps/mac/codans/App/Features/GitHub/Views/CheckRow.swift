import SwiftUI
import CodansCore

/// One row in the PR popover's check list. Name on the left, duration in the middle,
/// status glyph on the right. Failing rows get a trailing "View log" link.
struct CheckRow: View {
  let check: CheckResult
  let onOpenLog: (URL) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(check.name)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      if let duration = check.durationSeconds {
        Text(formatDuration(duration))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      statusGlyph
        .imageScale(.small)
      if case .completed = check.status,
        check.conclusion == .failure,
        let url = check.detailsURL
      {
        Button("View log") { onOpenLog(url) }
          .buttonStyle(.link)
          .font(.caption)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var statusGlyph: some View {
    switch (check.status, check.conclusion) {
    case (.completed, .success):
      Image(systemName: "checkmark.circle.fill").foregroundStyle(CheckRollupColor.passing)
    case (.completed, .failure):
      Image(systemName: "xmark.circle.fill").foregroundStyle(CheckRollupColor.failing)
    case (.completed, .cancelled), (.completed, .timedOut):
      Image(systemName: "minus.circle.fill").foregroundStyle(CheckRollupColor.neutral)
    case (.completed, .skipped), (.completed, .neutral):
      Image(systemName: "circle.dashed").foregroundStyle(CheckRollupColor.neutral)
    case (.completed, .actionRequired):
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(CheckRollupColor.failing)
    case (.completed, nil):
      Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
    case (.inProgress, _), (.queued, _), (.waiting, _), (.pending, _):
      Image(systemName: "circle.dotted").foregroundStyle(CheckRollupColor.pending)
    case (.completed, .stale), (.completed, .startupFailure):
      Image(systemName: "exclamationmark.triangle").foregroundStyle(CheckRollupColor.failing)
    }
  }

  private func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    let remaining = seconds % 60
    if remaining == 0 { return "\(minutes)m" }
    return "\(minutes)m \(remaining)s"
  }
}
