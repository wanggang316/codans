import ComposableArchitecture
import SwiftUI

/// The two workspace removal confirmations, extracted so the sidebar's
/// modifier chain stays under the type-checker limit.
///
/// Removing a member is destructive the way Delete Worktree is: the
/// checkout is moved out and its branch deleted. Removing a workspace
/// offers the entry-only default (nothing on disk changes) and the
/// delete-checkouts variant, which unregisters every member and deletes
/// the folder only when all of them could be unregistered.
struct WorkspaceRemovalDialogs: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        memberTitle,
        isPresented: Binding(
          get: { store.pendingWorkspaceMemberRemoval != nil },
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
        Text(
          "Unregisters the checkout from its repository, deletes its branch, and removes it from the workspace manifest. Its panes are closed."
        )
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
        Button("Remove and Delete Checkouts", role: .destructive) {
          store.send(.workspaceRemoveConfirmed(deleteFiles: true))
        }
        Button("Cancel", role: .cancel) {
          store.send(.workspaceRemoveCancelled)
        }
      } message: {
        Text(
          "Remove from Sidebar keeps every checkout and branch on disk. Remove and Delete Checkouts unregisters each member from its repository and deletes the workspace folder; branches are kept."
        )
      }
  }

  private var memberTitle: String {
    if let name = store.pendingWorkspaceMemberRemoval?.displayName {
      return "Remove “\(name)” from the workspace?"
    }
    return "Remove from workspace?"
  }

  private var workspaceTitle: String {
    if let name = store.pendingWorkspaceRemoval?.displayName {
      return "Remove Workspace “\(name)”?"
    }
    return "Remove Workspace?"
  }
}
