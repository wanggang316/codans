import SwiftUI

/// Full-window launch skeleton shown while `AppState.bringUp()` is still
/// constructing the TCA store / TerminalEngine / IPC stack (`store == nil`).
///
/// Instead of a bare centered spinner, it mirrors the real two-column
/// `NavigationSplitView` chrome that `ContentView` settles into — a
/// shimmering ghost sidebar on the left, the animated launch caption in the
/// detail pane, and ghost toolbar clusters up top — so the gap between the
/// window appearing and the store landing reads as "our app, loading"
/// rather than a frozen window. Purely cosmetic: it holds no TCA store and
/// reads no live catalog, so it renders before `bringUp()` finishes.
///
/// Reuses the shared `SkeletonBlock` / `SkeletonTextBar` / `shimmer`
/// primitives (and the toolbar clusters that back worktree creation) so the
/// launch skeleton stays flush with the rest of the app's placeholder look
/// and no second animation/skeleton system is introduced.
struct LaunchSkeletonView: View {
  var body: some View {
    NavigationSplitView {
      LaunchSidebarSkeleton()
        // Match `ContentView.mainSplit`'s sidebar column so the columns
        // don't resize when the real split view takes over on `bringUp`.
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    } detail: {
      // The rotating launch caption already lives in `AppBootstrapView`;
      // reuse it as the detail body so the skeleton reads as "loading"
      // without duplicating the message list.
      AppBootstrapView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { LaunchToolbarSkeleton() }
    }
    // The whole skeleton is decorative and non-interactive; keep it out of
    // the accessibility tree so VoiceOver never walks a user through ghost
    // rows that vanish the instant the store lands.
    .accessibilityHidden(true)
  }
}

/// Sidebar-column ghost. Mirrors the real `HierarchySidebarView` shell — a
/// `.sidebar`-styled `List` of grouped rows — with a fixed, representative
/// section shape (two "repositories", a few "worktree" rows each). The
/// header/row strings only size the shimmering bars via `SkeletonTextBar`'s
/// invisible-text footprint; they never render as glyphs, so the skeleton
/// stays generic and leaks no catalog contents.
private struct LaunchSidebarSkeleton: View {
  /// Representative section shape. Tuple, not a model type — this is pure
  /// layout scaffolding with no domain meaning.
  private static let sections: [(header: String, rows: Int)] = [
    ("repository-one", 3),
    ("repository-two", 2),
  ]

  var body: some View {
    List {
      ForEach(Self.sections.indices, id: \.self) { index in
        Section {
          ForEach(0..<Self.sections[index].rows, id: \.self) { _ in
            LaunchSidebarRowSkeleton()
              .listRowSeparator(.hidden)
          }
        } header: {
          SkeletonTextBar(
            text: Self.sections[index].header,
            font: .subheadline.weight(.semibold),
            barHeight: 8
          )
          .padding(.vertical, 2)
        }
      }
    }
    .listStyle(.sidebar)
    // Match the real sidebar: let the window/material background show
    // through instead of the List's own opaque fill.
    .scrollContentBackground(.hidden)
    // Nothing to scroll while loading; disabling avoids a rubber-band
    // bounce on the ghost rows.
    .scrollDisabled(true)
  }
}

/// One ghost worktree row: a leading icon block over a two-line identity
/// stack (branch headline + context caption), matching the real sidebar
/// row's leading-icon-plus-two-lines anatomy.
private struct LaunchSidebarRowSkeleton: View {
  var body: some View {
    HStack(spacing: 8) {
      SkeletonBlock(width: 16, height: 16)
      VStack(alignment: .leading, spacing: 3) {
        SkeletonTextBar(text: "feature/placeholder-branch", font: .body, barHeight: 9)
        SkeletonTextBar(text: "worktree", font: .caption, barHeight: 7)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
  }
}

/// Window-toolbar ghost. Reuses the geometry-matched clusters that stand in
/// for the worktree header during creation (`WorktreeToolbarSkeleton.swift`)
/// so the launch toolbar occupies the same footprint the real branch
/// identity / status pill / action buttons settle into. Every item is
/// `accessibilityHidden` — these are non-actionable placeholders.
private struct LaunchToolbarSkeleton: ToolbarContent {
  var body: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      SkeletonBranchClusterView(name: "feature/branch", projectName: "repository")
        .accessibilityHidden(true)
    }
    ToolbarItem(placement: .principal) {
      SkeletonStatusPillView()
        .accessibilityHidden(true)
    }
    ToolbarItemGroup(placement: .primaryAction) {
      SkeletonActionChipView(labelText: "Run")
      SkeletonActionChipView(labelText: "Open")
    }
  }
}

#Preview {
  LaunchSkeletonView()
    .frame(width: 900, height: 600)
}
