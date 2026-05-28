import Foundation
import SwiftUI
import TouchCodeCore

/// One row inside the Branch popover's "Recent commits" section. Not
/// tappable in this milestone — the spec deferred row-click → tab to a
/// Could-Have. The footer button drives the only navigation out of the
/// list.
struct RecentCommitRowView: View {
  let commit: Commit

  /// Single shared formatter — `RelativeDateTimeFormatter` allocations are
  /// non-trivial and a popover renders up to 10 rows per appearance. The
  /// implicit main-actor isolation of this `View` keeps the static let
  /// well-typed under Swift 6 without an explicit escape hatch (see
  /// `InboxRowView` for the same pattern).
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  private var shortSHA: String { commit.shortID }

  private var relativeAge: String {
    Self.relativeFormatter.localizedString(for: commit.date, relativeTo: Date())
  }

  var body: some View {
    HStack(spacing: 8) {
      Text(shortSHA)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .frame(width: 56, alignment: .leading)
      Text(commit.subject)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      Text(relativeAge)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .accessibilityIdentifier("branch_switcher.commit_row.\(shortSHA)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Commit \(shortSHA), \(commit.subject), \(relativeAge)")
  }
}

#Preview("commit row") {
  RecentCommitRowView(
    commit: Commit(
      id: "abcdef0123456789",
      authorName: "Ada Lovelace",
      authorEmail: "ada@example.com",
      date: Date().addingTimeInterval(-3_600),
      subject: "feat(switcher): wire popover content views",
      parents: []
    )
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}
