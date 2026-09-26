import Foundation

/// Curated everyday commands offered by the Global Commands pane. Unlike
/// Project suggestions they are not detected from files: global commands run
/// in whichever worktree is selected, so the list is tool-level workflows
/// that make sense in any repository.
///
/// Only non-destructive commands belong here — nothing that discards work
/// (`reset --hard`, `clean -fd`, force pushes). A new group is one more
/// entry in `groups`.
public nonisolated enum GlobalCommandSuggestions {
  public static let git = CommandSuggestionSource(id: "global-git", displayName: "Git")
  public static let github = CommandSuggestionSource(id: "global-gh", displayName: "GitHub CLI")

  public static let groups: [CommandSuggestionGroup] = [
    CommandSuggestionGroup(source: git, suggestions: [
      entry(git, "Status", "git status -sb", "Branch and changed files", "list.bullet.rectangle"),
      entry(git, "Pull (rebase)", "git pull --rebase --autostash", "Rebase local commits onto upstream", "arrow.down.circle"),
      entry(git, "Push", "git push", "Push the current branch", "arrow.up.circle"),
      entry(git, "Fetch & Prune", "git fetch --all --prune", "Update remotes, drop deleted branches", "arrow.triangle.2.circlepath"),
      entry(git, "Log Graph", "git log --oneline --graph --decorate -30", "Recent history as a graph", "point.3.connected.trianglepath.dotted"),
      entry(git, "Diff Summary", "git diff HEAD --stat", "Changed files against HEAD", "plus.forwardslash.minus"),
      entry(git, "Stash", "git stash push --include-untracked", "Set changes aside, untracked files too", "tray.and.arrow.down"),
      entry(git, "Stash Pop", "git stash pop", "Restore the latest stash", "tray.and.arrow.up"),
      entry(
        git, "Recent Branches", "git branch --sort=-committerdate --format='%(refname:short)' | head -15",
        "Branches by last commit", "clock.arrow.circlepath"),
    ]),
    CommandSuggestionGroup(source: github, suggestions: [
      entry(github, "Create PR", "gh pr create --web", "Open a new pull request in the browser", "arrow.triangle.pull"),
      entry(github, "View PR", "gh pr view --web", "Open this branch's pull request", "safari"),
      entry(github, "PR Checks", "gh pr checks --watch", "Follow CI for this branch's pull request", "checkmark.seal"),
      entry(github, "Workflow Runs", "gh run list --limit 10", "Latest Actions runs", "list.bullet.clipboard"),
    ]),
  ]

  private static func entry(
    _ source: CommandSuggestionSource, _ name: String, _ command: String, _ detail: String, _ symbol: String
  ) -> CommandSuggestion {
    CommandSuggestion(
      source: source, name: name, command: command, detail: detail, kind: .custom, icon: .symbol(symbol))
  }
}
