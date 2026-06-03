import SwiftUI

/// Detail-pane placeholder shown when no Worktree is selected — typically
/// on first launch before any Project has been added, or after the catalog
/// pruned every existing Project.
///
/// HAN-65: deliberately blank. The sidebar's empty-state view owns the
/// "Open Project" call-to-action and the shortcut hint, so the detail
/// pane only needs to surface the window's background colour. Suppressing
/// the title + toolbar chrome in `WorktreeDetailView`'s placeholder branch
/// removes the lingering "touch-code" window title and the title-bar
/// divider; this view fills what's left.
///
/// Parameter is kept on the type so call sites that already thread a
/// sidebar-add hook in don't need to change — it is currently unused,
/// but the empty-state surface might gain a button again later.
struct EmptyProjectStateView: View {
  let onAddProject: () -> Void

  // Fill with the active Ghostty terminal background — the same tone
  // `WindowAppearanceSetter` stains `NSWindow.backgroundColor` with for
  // sidebar blending — so the no-project body reads as one continuous
  // surface with the sidebar + title-bar chrome instead of a white body
  // framed by the gray stain. `.ignoresSafeArea()` extends the fill behind
  // the hidden window-toolbar chrome so the title-bar region matches too.
  var body: some View {
    GhosttyBackground()
      .ignoresSafeArea()
  }
}

#Preview {
  EmptyProjectStateView(onAddProject: {})
    .frame(width: 600, height: 400)
}
