import ComposableArchitecture
import SwiftUI

/// Presents the sidebar's own sheets — New Worktree, Clone Repository, and
/// Archived Worktrees — off the sidebar store. Extracted into a
/// `ViewModifier` (applied as a single `.modifier(...)`) for the same reason
/// as `RemoteConnectionSheetPresenter`: inline `.sheet` modifiers with their
/// binding and scope closures push the sidebar's `body` past the Swift
/// type-checker's inference budget.
///
/// Each goes through `childSheet`, which keeps the sheet's content through
/// the dismissal animation instead of collapsing into a blank card.
struct SidebarSheetPresenter: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content
      .childSheet(
        store.scope(state: \.createWorktreeSheet, action: \.createWorktreeSheet),
        onDismiss: { store.send(.createWorktreeSheet(.cancelButtonTapped)) },
        content: { childStore in
          CreateWorktreeSheet(store: childStore)
        }
      )
      .childSheet(
        store.scope(state: \.cloneRepoSheet, action: \.cloneRepoSheet),
        onDismiss: { store.send(.cloneRepoSheet(.cancelButtonTapped)) },
        content: { childStore in
          CloneRepoSheet(store: childStore)
            .interactiveDismissDisabled(store.cloneRepoSheet?.isCloning ?? false)
        }
      )
      // Opened from the Project ⋯ menu.
      .childSheet(
        store.scope(state: \.archivedWorktreesSheet, action: \.archivedWorktreesSheet),
        onDismiss: { store.send(.archivedWorktreesSheetDismissed) },
        content: { childStore in
          ArchivedWorktreesSheet(store: childStore)
        }
      )
  }
}
