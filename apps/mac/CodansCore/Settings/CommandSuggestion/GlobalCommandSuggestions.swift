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
  public static let docker = CommandSuggestionSource(id: "global-docker", displayName: "Docker")
  public static let system = CommandSuggestionSource(id: "global-system", displayName: "System")
  public static let homebrew = CommandSuggestionSource(id: "global-brew", displayName: "Homebrew")

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
      entry(git, "Last Commit", "git show --stat HEAD", "The latest commit and its files", "doc.text.magnifyingglass"),
      entry(git, "Today's Commits", "git log --since=midnight --oneline", "What was committed today", "calendar"),
      entry(git, "Worktrees", "git worktree list", "Every worktree of this repository", "rectangle.stack"),
      entry(
        git, "Update Submodules", "git submodule update --init --recursive", "Check out the recorded submodule commits",
        "square.stack.3d.down.right"),
      // `-d` (never `-D`) refuses any branch that is not fully merged; `+`
      // marks branches checked out in another worktree.
      entry(
        git, "Delete Merged Branches",
        "git branch --merged | grep -vE '^[*+]|^ *(main|master|develop)$' | xargs -n 1 git branch -d",
        "Local branches already merged into this one", "scissors"),
    ]),
    CommandSuggestionGroup(source: github, suggestions: [
      entry(github, "Create PR", "gh pr create --web", "Open a new pull request in the browser", "arrow.triangle.pull"),
      entry(github, "View PR", "gh pr view --web", "Open this branch's pull request", "safari"),
      entry(github, "PR Checks", "gh pr checks --watch", "Follow CI for this branch's pull request", "checkmark.seal"),
      entry(github, "Workflow Runs", "gh run list --limit 10", "Latest Actions runs", "list.bullet.clipboard"),
      entry(github, "Watch Run", "gh run watch", "Follow a running workflow", "eye"),
      entry(github, "PR Status", "gh pr status", "Pull requests relevant to you here", "person.crop.rectangle.stack"),
      entry(github, "My PRs", "gh pr list --author @me", "Open pull requests you authored", "person"),
      entry(github, "My Issues", "gh issue list --assignee @me", "Open issues assigned to you", "exclamationmark.circle"),
      entry(github, "Open Repository", "gh repo view --web", "The repository on GitHub", "globe"),
    ]),
    CommandSuggestionGroup(source: docker, suggestions: [
      entry(docker, "Running Containers", "docker ps", "Containers that are up", "shippingbox"),
      entry(docker, "Compose Up", "docker compose up -d", "Start this directory's stack in the background", "play.circle"),
      entry(docker, "Compose Down", "docker compose down", "Stop and remove the stack's containers", "stop.circle"),
      entry(docker, "Compose Logs", "docker compose logs -f --tail=100", "Follow the stack's logs", "doc.text"),
      entry(docker, "Disk Usage", "docker system df", "Space used by images, containers, volumes", "internaldrive"),
    ]),
    CommandSuggestionGroup(source: system, suggestions: [
      entry(
        system, "Listening Ports", "lsof -iTCP -sTCP:LISTEN -n -P", "Which process holds which port", "network"),
      entry(system, "Folder Sizes", "du -sh * .[!.]* 2>/dev/null | sort -h", "Size of each entry here, largest last", "chart.bar.xaxis"),
      entry(system, "Environment", "env | sort", "Variables the shell sees", "list.bullet.indent"),
    ]),
    CommandSuggestionGroup(source: homebrew, suggestions: [
      entry(homebrew, "Outdated", "brew update && brew outdated", "Refresh Homebrew and list upgradable formulae", "arrow.up.circle"),
      entry(homebrew, "Doctor", "brew doctor", "Check the Homebrew install for problems", "stethoscope"),
    ]),
  ]

  private static func entry(
    _ source: CommandSuggestionSource, _ name: String, _ command: String, _ detail: String, _ symbol: String
  ) -> CommandSuggestion {
    CommandSuggestion(
      source: source, name: name, command: command, detail: detail, kind: .custom, icon: .symbol(symbol))
  }
}
