import ComposableArchitecture
import SwiftUI
import CodansCore

/// Sheet listing a Project's archived Worktrees with Unarchive /
/// Remove actions per row. State flows through
/// `ArchivedWorktreesFeature`; the structural list of archived
/// worktrees is read live from `HierarchyManager.catalog` on every
/// render.
struct ArchivedWorktreesSheet: View {
  @Bindable var store: StoreOf<ArchivedWorktreesFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    let archived = archivedWorktrees()
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Archived Worktrees").font(.headline)
        Spacer()
        Button("Close") { store.send(.closeButtonTapped) }
          .keyboardShortcut(.cancelAction)
      }
      if let banner = store.banner {
        Text(banner)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if archived.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "archivebox")
            .font(.title)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("No archived worktrees.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(archived) { worktree in
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(worktree.name)
                  .lineLimit(1)
                if let branch = worktree.branch {
                  Text(branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Text(worktree.path)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer()
              Button("Unarchive") {
                store.send(.unarchiveTapped(worktree.id))
              }
              .buttonStyle(.borderless)
              Button(role: .destructive) {
                store.send(.removeTapped(worktree.id, displayName: worktree.name))
              } label: {
                Image(systemName: "trash")
                  .accessibilityLabel("Remove Worktree")
              }
              .buttonStyle(.borderless)
              .help("Remove")
            }
            .padding(.vertical, 4)
          }
        }
        .listStyle(.inset)
      }
    }
    .padding(20)
    .frame(width: 480, height: 360)
    .confirmationDialog(
      removalTitle,
      isPresented: Binding(
        get: { store.pendingRemoval != nil },
        set: { if !$0 { store.send(.removeCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove Worktree", role: .destructive) {
        store.send(.removeConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.removeCancelled)
      }
    } message: {
      Text(
        "Closes all panes and deletes the Worktree directory, including any uncommitted changes. This cannot be undone."
      )
    }
  }

  private func archivedWorktrees() -> [Worktree] {
    let catalog = hierarchyManager.catalog
    guard let project = catalog.projects.first(where: { $0.id == store.projectID })
    else { return [] }
    return project.worktrees.filter { $0.archived }
  }

  private var removalTitle: String {
    guard let pending = store.pendingRemoval else { return "Remove Worktree?" }
    return "Remove “\(pending.worktreeName)”?"
  }
}
