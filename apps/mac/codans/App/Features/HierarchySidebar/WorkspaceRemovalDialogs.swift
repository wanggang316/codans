import CodansCore
import ComposableArchitecture
import SwiftUI

/// A source project about to leave a Workspace. Captured when the user asks,
/// so the confirmation names the row and the terminals it stops even if the
/// catalog changes before the answer. Shared by the sidebar and Settings.
struct PendingWorkspaceSourceRemoval: Equatable {
  var projectID: ProjectID
  var worktreeID: WorktreeID
  var displayName: String
  var sourceGitRoot: String
  /// Busy tabs of the reference row. Removing the reference closes them;
  /// the source project's own rows are not touched.
  var runningTerminals: [String]

  /// `nil` unless `worktreeID` is a reference row: only a source project
  /// leaves a Workspace on its own; a group member goes with its group.
  @MainActor
  init?(worktreeID: WorktreeID, in project: Project, tabIsDirty: (TabID) -> Bool) {
    guard let row = project.worktrees.first(where: { $0.id == worktreeID }),
      row.workspaceSlot?.role == .reference
    else { return nil }
    self.projectID = project.id
    self.worktreeID = worktreeID
    self.displayName = row.name
    self.sourceGitRoot = row.sourceGitRoot ?? row.path
    self.runningTerminals = RunningTerminalNames.names(in: row) { tabIsDirty($0.id) }
  }

  var title: String { "Remove “\(displayName)” from the workspace?" }

  var message: String {
    var text =
      "The project leaves the workspace and its default group. Its folder and branches do not change, and existing groups keep their checkouts."
    if !runningTerminals.isEmpty {
      text += " These terminals stop: \(runningTerminals.joined(separator: ", "))."
    }
    return text
  }
}

/// The Workspace confirmations, extracted so the sidebar's modifier chain
/// stays under the type-checker limit: a source project leaving the
/// Workspace, and Remove Workspace (sidebar only, or on to the delete sheet
/// that `SidebarSheetPresenter` shows).
struct WorkspaceRemovalDialogs: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        store.pendingWorkspaceSourceRemoval?.title ?? "Remove from workspace?",
        isPresented: Binding(
          get: { store.pendingWorkspaceSourceRemoval != nil },
          set: { if !$0 { store.send(.workspaceMemberRemoveCancelled) } }
        ),
        titleVisibility: .visible
      ) {
        Button("Remove from Workspace", role: .destructive) {
          store.send(.workspaceMemberRemoveConfirmed)
        }
        Button("Cancel", role: .cancel) {
          store.send(.workspaceMemberRemoveCancelled)
        }
      } message: {
        Text(store.pendingWorkspaceSourceRemoval?.message ?? "")
      }
      .confirmationDialog(
        workspaceTitle,
        isPresented: Binding(
          get: { store.pendingWorkspaceRemoval != nil },
          set: { if !$0 { store.send(.workspaceRemoveCancelled) } }
        ),
        titleVisibility: .visible
      ) {
        Button("Remove from Sidebar") {
          store.send(.workspaceRemoveConfirmed(deleteFiles: false))
        }
        Button("Delete Workspace Files…", role: .destructive) {
          store.send(.workspaceRemoveConfirmed(deleteFiles: true))
        }
        Button("Cancel", role: .cancel) {
          store.send(.workspaceRemoveCancelled)
        }
      } message: {
        Text(
          "Remove from Sidebar keeps every file on disk. Delete Workspace Files deletes the groups, their checkouts, and the workspace folder. Source projects are never deleted."
        )
      }
  }

  private var workspaceTitle: String {
    if let name = store.pendingWorkspaceRemoval?.displayName {
      return "Remove Workspace “\(name)”?"
    }
    return "Remove Workspace?"
  }
}
