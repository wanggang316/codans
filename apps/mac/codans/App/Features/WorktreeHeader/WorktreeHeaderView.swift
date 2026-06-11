import ComposableArchitecture
import SwiftUI
import CodansCore

/// Top Header row above the terminal Tab bar. Left: read-only branch label.
/// Right: Open-in split button. The Git Viewer is no longer a header chip —
/// it lives behind the ⌘⌥G chord / menu and routes through the user's
/// `settings.general.defaultGitViewerID` choice.
struct WorktreeHeaderView: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  let editorStore: StoreOf<EditorFeature>
  let projectID: ProjectID
  let worktreePath: String
  let branchLabel: String
  /// Gates the branch label for non-git Projects (P-Q4 = a). Defaults to
  /// `true` so existing call sites that haven't threaded the predicate still
  /// render the branch chip.
  var supportsWorktrees: Bool = true

  var body: some View {
    HStack(spacing: 10) {
      if supportsWorktrees {
        Label(branchLabel, systemImage: "point.3.connected.trianglepath.dotted")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityLabel("Current branch: \(branchLabel)")
          .accessibilityAddTraits(.isStaticText)
      }

      HStack(spacing: 6) {
        HeaderOpenSplitButton(
          store: store,
          editorStore: editorStore,
          projectID: projectID,
          worktreePath: worktreePath
        )
      }
    }
  }
}
