import CodansCore
import ComposableArchitecture
import SwiftUI

/// One source project in the Add Workspace / Add Project list: an icon for
/// where it comes from (the project's own icon, a folder on disk, or a
/// remote), its name, the source path or URL, and its problems. Remove sits
/// on the trailing edge; a remote also has Edit for its clone folder.
struct WorkspaceSourceRow: View {
  let store: StoreOf<CreateWorkspaceFeature>
  let source: SourceDraft

  var body: some View {
    HStack(spacing: 10) {
      icon
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(source.source.title)
          .fontWeight(.medium)
          .lineLimit(1)
        Text(source.source.location)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(sourceHelp)
        issues
      }
      Spacer(minLength: 8)
      if !store.creation.isBusy {
        trailing
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var icon: some View {
    switch source.source {
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
    switch source.source {
    case .project(_, _, let gitRoot):
      return "Open project at \(gitRoot)"
    case .localRepo(let gitRoot):
      return "Repository at \(gitRoot)"
    case .remote(let url, let cloneDestination):
      return "\(url), cloned to \(cloneDestination)"
    }
  }

  @ViewBuilder
  private var issues: some View {
    let shown = store.state.issues(for: source).filter { $0.severity != .incomplete }
    ForEach(Array(shown.enumerated()), id: \.offset) { _, issue in
      Text(issue.message)
        .font(.subheadline)
        .foregroundStyle(issue.severity == .blocking ? Color.red : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var trailing: some View {
    HStack(spacing: 12) {
      if source.source.isRemote {
        Button {
          store.send(.editRemoteTapped(source.id))
        } label: {
          Image(systemName: "pencil")
            .accessibilityLabel("Edit \(source.source.title)")
        }
        .buttonStyle(.borderless)
        .help("Edit")
      }
      Button(role: .destructive) {
        store.send(.removeSourceTapped(source.id))
      } label: {
        Image(systemName: "trash")
          .accessibilityLabel("Remove \(source.source.title)")
      }
      .buttonStyle(.borderless)
      .help("Remove")
    }
  }
}
