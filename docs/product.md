# Codans

Codans is a native macOS development environment for coding agents that run in a terminal. Each task gets its own worktree. Codans shows the state of each agent and takes the task from the prompt to the merged Pull Request.

The terminal is the primary surface. Codans is not an editor and not an agent: it is the environment in which agents such as Claude Code and Codex run.

For terms, see the [glossary](glossary.md). For the structure of the code, see the [architecture](architecture.md).

## Who it is for

Codans is for a developer who does most coding through CLI agents, works on several projects each day, and runs tasks in parallel in git worktrees.

It is not for a developer who wants a GUI editor as the primary tool, and not for a team that needs shared sessions.

## Core model

Codans puts terminals in a hierarchy of four levels:

| Level | Meaning |
|---|---|
| Project | A git repository, a plain folder, a Remote Project, or a Workspace. Each Project is on one Host. |
| Worktree | One checkout of a Project, with its own directory, branch, Tabs, and Panes. A plain folder has one Worktree. |
| Tab | A group of Panes in a Worktree. One Tab is visible at a time. |
| Pane | One terminal session. The Panes of a Tab make a split layout. |

Codans ships three artifacts with one version:

- **The app**: the window, the terminal runtime, and all state.
- **The `codans` CLI**: a client of the running app. The app adds it to the `PATH` of each local Pane.
- **The Agent Skills**: `codans-cli` and `codans-workflow`. They tell an agent how to use the CLI. `codans skill install` links them into the skill folders of Claude Code and Codex, or into the shared agent folder.

## Capabilities

### Agents

- **Agents View**: a sidebar panel that lists each agent in each Project with its agent runtime state: idle, working, blocked, done, or error. A click on a row goes to the Pane. See [agent state](domains/agent-state.md).
- **New Agent**: one dialog takes a Project, a new or existing Worktree, a prompt, and an agent. The Worktree and the agent start together.
- **Agent Profiles**: launch presets with agent, model, effort, mode, placement, arguments, and environment. You edit them in Settings and start them from the command palette or with `codans agent launch`. See [agent profiles and handoff](domains/agent-profiles-and-handoff.md).
- **Hand Off**: the agent in a Pane writes a briefing, and a second agent starts with it. Entry points are the Pane menu, the command palette, and `codans handoff`.
- **Workflows (Beta)**: YAML files that connect agents into sequences and loops, such as author and reviewer. Three workflows are built in: `review-loop`, `handoff`, and `advisor`. You start a workflow from the command palette or with `codans workflow run`. See [workflow](domains/workflow.md).
- **Command Queue**: a list of prompts for one Pane. A prompt can run after the current task, immediately, or at a scheduled time with an optional repeat interval. See [command queue](domains/command-queue.md).
- **Session history**: the Claude Code and Codex sessions of a Worktree. You resume a session in a new Tab, in a new split, or in the focused Pane.
- **Agent Skill completion**: the prompt fields of the New Agent dialog and the Command Queue complete the names of the Agent Skills that the selected agent can load. See [agent skill completion](domains/agent-skill-completion.md).
- **Notifications**: when an agent asks for input or completes a task, the Worktree gets an unread mark, the Dock icon gets a badge, and macOS shows a banner that goes to the Pane. See [notifications](domains/notifications.md).

Codans identifies these agents: Claude Code, Codex, Pi, OpenCode, Gemini CLI, Cursor Agent, Cline, GitHub Copilot, Kimi, Droid, Amp, Grok Build, and omp. Other terminal programs run as usual, without agent state.

### Projects and Worktrees

- **Worktree operations**: create, switch, rename, archive, delete, and prune Worktrees, and switch the branch of a Worktree, from the sidebar, the Worktree header, the command palette, or the CLI. See [worktree](domains/worktree.md).
- **Sidebar state**: each Worktree row shows its diff size, its Pull Request, an indicator while a command or an agent runs, and its unread notifications. Filters limit the sidebar to Remote Projects, Workspaces, Worktrees with a Pull Request, or Worktrees with unread notifications. See [main window](domains/main-window.md).
- **Workspaces**: a Workspace groups several source projects. Each workspace group has one member checkout for each source project, so one agent can change all of them. See [workspace](domains/workspace.md).
- **Remote Projects**: a Project on a different Host, which Codans reaches over SSH. Hosts are records in Settings. See [remote projects](domains/remote-projects.md).
- **Project commands**: commands that you bind to the Run button of a Project, and global commands for all Projects. Codans suggests commands from project files such as `package.json` and `Makefile`. See [project commands](domains/project-commands.md).

### Terminals

- **Terminal engine**: libghostty renders each Pane. Tabs hold split layouts that you resize, zoom, and equalize. See [terminal runtime](domains/terminal-runtime.md).
- **Persistent sessions**: a session daemon owns each terminal session. When you quit Codans, you can keep the sessions in operation or save a snapshot. The subsequent launch restores Projects, Worktrees, Tabs, split layouts, and terminals.
- **Themes**: all Ghostty themes are built in. You select one theme for the light appearance and one for the dark appearance, and the window takes its colors from the theme. See [appearance](domains/appearance.md).

### Pull Requests and changes

- **Git Platform integration**: Pull Request badges, check status, and review status for GitHub and for GitLab, which includes self-managed GitLab. You can merge, close, mark ready, and rerun failed jobs. Codans calls `gh` and `glab`. It sends no HTTP request to a Git Platform and stores no token. See [git platform](domains/git-platform.md).
- **Diff viewer**: a read-only window that shows the uncommitted changes and the outgoing changes of a Worktree, in unified or split layout. See [git diff viewer](domains/git-diff-viewer.md).
- **External tools**: open a Worktree in an editor, a terminal, or a git client that is installed, from the Worktree header, the command palette, or `codans open`. The default editor is a setting, global and for each Project. See [editor integration](domains/editor-integration.md).

### Control surfaces

- **Command palette**: a search field that finds the actions of the app, the Worktrees, the Agent Profiles, the workflows, and the commands. See [command palette](domains/command-palette.md).
- **Keyboard shortcuts**: each action has a shortcut that you can change, disable, or reset in Settings. See [keyboard shortcuts](domains/keyboard-shortcuts.md).
- **CLI**: `codans` reads the hierarchy (`tree`, `status`), manages Projects, Worktrees, Tabs, and Panes, sends text and keys to a Pane, reads the screen of a Pane, broadcasts input to many Panes, reads and waits for agent state, starts agents, and operates Workspaces and workflows. See [CLI](domains/cli.md).
- **Settings**: one window for general options, agents, workflows, Git Platforms, Hosts, terminal, notifications, commands, shortcuts, and updates. See [settings](domains/settings.md).

## Platform and distribution

- macOS 14 or later, on Apple Silicon.
- Free and open source, with the MIT License.
- Installation is through a Homebrew cask or a disk image from the GitHub releases. The cask also links the `codans` CLI.
- The app updates itself. See [updates and release](domains/updates-and-release.md).
- Pull Request features need `gh` or `glab`, installed and logged in. A Remote Project needs SSH access to its Host.

## Boundaries

Codans does not do these things:

- **Edit code.** There is no text editor, no language server, and no source browser. The diff viewer is read-only. Editing goes to an external editor.
- **Supply an agent.** Codans starts and monitors the agents that you install.
- **Replace a git client.** There is no UI to stage, commit, rebase, or stash, and no history browser or merge editor. Worktree operations, branch switches, and Pull Request actions are the only git operations in the app.
- **Replace the Git Platform website.** Issues, review threads, pipeline dashboards, and auto-merge are not in the app. GitHub and GitLab are the only Git Platforms.
- **Call Git Platform APIs or store credentials.** Authentication stays with `gh`, `glab`, and SSH.
- **Implement a terminal emulator.** Terminal rendering is libghostty.
- **Support collaboration.** There are no shared sessions.
- **Run on other platforms.** There is no Windows, Linux, or browser version, and no dev-container orchestration.
- **Load or run Agent Skills.** A skill is text that the agent reads. Codans only links the bundled skills into agent folders.
