import CodansCore
import ComposableArchitecture
import SwiftUI

/// One project in the New Workspace list: an icon for where it comes from
/// (the project's own icon, a folder on disk, or a remote), its folder name
/// and source, the checkout as `WorkspaceCheckoutLine` draws it, and its
/// problems or creation progress. Edit and remove sit on the trailing edge.
/// A workspace's settings page lists its checkouts in the same shape.
struct WorkspaceMemberRow: View {
  let store: StoreOf<CreateWorkspaceFeature>
  let member: MemberDraft

  var body: some View {
    HStack(spacing: 10) {
      icon
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(member.name.isEmpty ? member.source.title : member.name)
            .fontWeight(.medium)
            .lineLimit(1)
            .layoutPriority(1)
          Text(member.source.location)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(sourceHelp)
        }
        WorkspaceCheckoutLine(checkout: store.state.checkoutDescription(for: member))
        statusLine
      }
      Spacer(minLength: 8)
      trailing
    }
    .padding(.vertical, 2)
  }

  // MARK: Icon

  @ViewBuilder
  private var icon: some View {
    switch member.source {
    case .project(let id, _, _):
      let candidate = store.candidates[id: id]
      ProjectIconView(icon: candidate?.icon, color: candidate?.color, size: 16)
    case .localRepo:
      symbol("folder", tint: .secondary)
    case .remote:
      symbol("globe", tint: .blue)
    }
  }

  private func symbol(_ name: String, tint: Color) -> some View {
    Image(systemName: name)
      .foregroundStyle(tint)
      .accessibilityHidden(true)
  }

  private var sourceHelp: String {
    switch member.source {
    case .project(_, _, let gitRoot):
      return "Open project at \(gitRoot)"
    case .localRepo(let gitRoot):
      return "Repository at \(gitRoot)"
    case .remote(let url, let cloneDestination):
      return "\(url), cloned to \(cloneDestination)"
    }
  }

  // MARK: Status

  @ViewBuilder
  private var statusLine: some View {
    switch member.progress {
    case .pending where store.creation.isBusy:
      caption("Waiting…")
    case .pending:
      let issues = store.state.issues(for: member).filter { $0.severity == .blocking || $0.severity == .warning }
      ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
        Text(issue.message)
          .font(.subheadline)
          .foregroundStyle(issue.severity == .blocking ? .red : .orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    case .running(let phase, let lastLine):
      caption([phaseTitle(phase), lastLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
    case .done:
      EmptyView()
    case .failed(let message):
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    case .rolledBack:
      caption("Rolled back.")
    }
  }

  private func caption(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  private func phaseTitle(_ phase: WorkspaceCreationEvent.Phase) -> String {
    switch phase {
    case .cloning: return "Cloning…"
    case .fetching: return "Fetching…"
    case .checkingOut: return "Checking out…"
    }
  }

  // MARK: Trailing

  @ViewBuilder
  private var trailing: some View {
    switch member.progress {
    case .running:
      ProgressView().controlSize(.small)
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Checked out")
    case .pending where store.creation.isBusy:
      EmptyView()
    case .pending, .failed, .rolledBack:
      HStack(spacing: 12) {
        if member.refs.isLoading {
          ProgressView().controlSize(.mini)
            .help("Loading branches")
        }
        Button {
          store.send(.editTapped(member.id))
        } label: {
          Image(systemName: "pencil")
            .accessibilityLabel("Edit \(member.name)")
        }
        .buttonStyle(.borderless)
        .help("Edit")
        Button(role: .destructive) {
          store.send(.member(member.id, .remove))
        } label: {
          Image(systemName: "trash")
            .accessibilityLabel("Remove \(member.name)")
        }
        .buttonStyle(.borderless)
        .help("Remove")
      }
    }
  }
}
