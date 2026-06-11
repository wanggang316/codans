import AppKit
import ComposableArchitecture
import Foundation

/// Handles the `GitHubFeature.Action.delegate(...)` fan-out for the root app shell.
///
/// Landed as a standalone `Reducer` (rather than inline branches in `RootFeature`'s switch)
/// because adding the detail to the root switch overwhelmed Swift 6's type-inference budget
/// for the result-builder expression ("unable to type-check in reasonable time"). Extracting
/// the handler keeps the root body slim and moves the AppKit import boundary away from the
/// root reducer.
///
/// Scoped from `RootFeature` via `Scope(state: \.gitHub, action: \.gitHub)` so each delegate
/// action drops through both the child reducer and this one in turn.
struct GitHubRootBindings: Reducer {
  @Dependency(SettingsWindowPresenter.self) private var settingsWindowPresenter

  var body: some Reducer<GitHubFeature.State, GitHubFeature.Action> {
    Reduce { _, action in
      switch action {
      case .delegate(.openURL(let url)):
        return .run { _ in
          await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }

      case .delegate(.showSettingsGitHub):
        let presenter = settingsWindowPresenter
        return .run { _ in
          await MainActor.run { presenter.open() }
        }

      case .delegate(.pullRequestMerged):
        // M7 expands this branch to dispatch the post-merge Worktree action (archive /
        // delete / ask). Today the delegate is a no-op — the popover's success path
        // already refreshes the badge via the reducer's own .mergeCompleted handler.
        return .none

      default:
        return .none
      }
    }
  }
}
