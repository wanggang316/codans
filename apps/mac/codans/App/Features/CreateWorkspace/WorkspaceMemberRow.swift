import ComposableArchitecture
import Foundation
import SwiftUI

/// One-line summary of a member: source glyph, folder name, where it comes
/// from, how it is checked out, and the row's status. Tap to expand into
/// `WorkspaceMemberDetail`. During creation the second line streams the
/// member's progress.
struct WorkspaceMemberRow: View {
  let member: MemberDraft
  let issues: [MemberIssue]
  let isExpanded: Bool
  let isCreating: Bool
  let send: (CreateWorkspaceFeature.Action.MemberAction) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      send(.toggleExpanded)
    } label: {
      HStack(spacing: 8) {
        leadingGlyph
          .frame(width: 16)
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(member.name)
              .font(.callout.weight(.medium))
              .lineLimit(1)
              .shimmer(isActive: member.progress.isRunning && !reduceMotion)
            Text(member.source.displayLocation)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          if isCreating || member.progress != .pending {
            Text(progressLine)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          } else {
            Text(checkoutSummary)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer(minLength: 8)
        trailingStatus
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(member.name), \(checkoutSummary)")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
  }

  @ViewBuilder
  private var leadingGlyph: some View {
    switch member.progress {
    case .running:
      ProgressView().controlSize(.mini)
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
    case .rolledBack:
      Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary).accessibilityLabel("Rolled back")
    case .pending:
      Image(systemName: sourceSymbol)
        .foregroundStyle(.secondary)
        .accessibilityLabel(sourceLabel)
    }
  }

  private var sourceSymbol: String {
    switch member.source {
    case .project, .localRepo: return "folder"
    case .bareRepo: return "archivebox"
    case .remote: return "globe"
    }
  }

  private var sourceLabel: String {
    switch member.source {
    case .project: return "Open project"
    case .localRepo: return "Local repository"
    case .bareRepo: return "Bare repository"
    case .remote: return "Remote repository"
    }
  }

  private var checkoutSummary: String {
    switch member.mode {
    case .newBranch:
      let base = member.baseRef ?? member.refs.inventory?.defaultBaseRef.map { "\($0) (default)" } ?? "default branch"
      return "new  \(member.branch.isEmpty ? "?" : member.branch)  ←  \(base)"
    case .existingLocal:
      return "existing  \(member.branch.isEmpty ? "?" : member.branch)"
    case .existingRemote:
      let ref = member.remoteRef ?? "?"
      let reset = member.hasLocalConflict && member.localConflict == .resetToRemote ? "  (reset local)" : ""
      return "remote  \(ref)\(member.branch == member.remoteRefBranch ? "" : "  as \(member.branch)")\(reset)"
    }
  }

  private var progressLine: String {
    switch member.progress {
    case .pending: return "Waiting…"
    case .running(let phase, let lastLine):
      if let lastLine, !lastLine.isEmpty { return lastLine }
      switch phase {
      case .cloning: return "Cloning…"
      case .fetching: return "Fetching…"
      case .checkingOut: return "Checking out…"
      }
    case .done: return "Checked out \(member.branch)"
    case .failed(let message): return message
    case .rolledBack: return "Rolled back"
    }
  }

  @ViewBuilder
  private var trailingStatus: some View {
    let blocking = issues.filter { $0.severity == .blocking }.count
    let warnings = issues.filter { $0.severity == .warning }.count
    if member.progress != .pending || isCreating {
      EmptyView()
    } else if member.refs.isLoading, member.mode == .existingRemote {
      ProgressView().controlSize(.mini)
    } else if blocking > 0 {
      countBadge(blocking, color: .red, label: "\(blocking) blocking")
    } else if warnings > 0 {
      countBadge(warnings, color: .orange, label: "\(warnings) warning")
    } else if member.refs.isLoading {
      ProgressView().controlSize(.mini)
    } else {
      Image(systemName: "checkmark")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityLabel("Ready")
    }
  }

  private func countBadge(_ count: Int, color: Color, label: String) -> some View {
    Text("\(count)")
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(color, in: Capsule())
      .accessibilityLabel(label)
  }
}
