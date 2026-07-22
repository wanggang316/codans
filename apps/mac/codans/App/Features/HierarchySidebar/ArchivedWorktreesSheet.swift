import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet listing a Project's archived Worktrees with Unarchive /
/// Remove actions per row. State flows through
/// `ArchivedWorktreesFeature`; the structural list of archived
/// worktrees is read live from `HierarchyManager.catalog` on every
/// render.
struct ArchivedWorktreesSheet: View {
  @Bindable var store: StoreOf<ArchivedWorktreesFeature>
  @Environment(HierarchyManager.self) private var hierarchyManager

  /// Horizontal inset shared by the header, banner, list rows, and
  /// footer so their content edges line up while the List itself spans
  /// the full sheet width (scroller flush with the trailing edge).
  private static let contentInset: CGFloat = 20

  var body: some View {
    let archived = archivedWorktrees()
    VStack(alignment: .leading, spacing: 12) {
      Text("Archived Worktrees")
        .font(.headline)
        .padding(.horizontal, Self.contentInset)
        .padding(.top, Self.contentInset)
      if let banner = store.banner {
        Text(banner)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Self.contentInset)
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
                if let archivedAt = worktree.archivedAt {
                  Text(archiveTimeline(archivedAt: archivedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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
            .listRowInsets(
              EdgeInsets(
                top: 4, leading: Self.contentInset,
                bottom: 4, trailing: Self.contentInset
              )
            )
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
      HStack {
        Spacer()
        Button("Close") { store.send(.closeButtonTapped) }
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, Self.contentInset)
      .padding(.bottom, 16)
    }
    .frame(width: 480, height: 400)
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

  /// Row caption: archive timestamp in a fixed `yyyy-MM-dd HH:mm`
  /// format.
  private func archiveTimeline(archivedAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return "Archived \(formatter.string(from: archivedAt))"
  }

  private var removalTitle: String {
    guard let pending = store.pendingRemoval else { return "Remove Worktree?" }
    return "Remove “\(pending.worktreeName)”?"
  }
}
