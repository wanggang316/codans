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

  // Neutral system tone, deliberately independent of the active Ghostty
  // palette: with no project there is no terminal to blend against, and a
  // dark-only Ghostty theme would otherwise paint a dark body next to the
  // system-appearance (light) sidebar. `.ignoresSafeArea()` extends the
  // fill behind the hidden window-toolbar chrome so the Ghostty-coloured
  // `NSWindow.backgroundColor` stain (applied by `WindowAppearanceSetter`
  // for sidebar blending) does not bleed through the title-bar region.
  // `WorktreeDetailView` also suppresses the Ghostty chrome-tint band in
  // this placeholder state so the whole no-project window stays neutral.
  var body: some View {
    Color(nsColor: .windowBackgroundColor)
      .ignoresSafeArea()
  }
}

#Preview {
  EmptyProjectStateView(onAddProject: {})
    .frame(width: 600, height: 400)
}
