# Documentation

This directory holds the current knowledge of the project: what the system does
today, the constraints a change must respect, and the reasons that are hard to
find again. Designs and execution plans are not kept here. They live in tickets
and pull requests as records of one delivery.

## Where to look

| Location | Read it when |
|---|---|
| [product.md](product.md) | You need to know what Codans is, for whom, and where its boundaries are |
| [architecture.md](architecture.md) | You need module responsibilities, dependency direction, or a cross-module invariant |
| [glossary.md](glossary.md) | You name a domain concept. Use its terms and avoid the synonyms it rejects |
| [domains/](domains/) | You change or debug one area. Each page owns the behavior contract of its topic |
| [adrs/](adrs/) | You want the reason for a decision, or your change contradicts one |
| [runbooks/](runbooks/) | You do an operation: crash reporting setup, the Homebrew cask, adding a tool mark |
| [lessons-learned/](lessons-learned/) | You see a failure that looks familiar. Each page is the root cause of one incident |
| [agents/domain.md](agents/domain.md) | You are an agent skill that reads the glossary and the decision records |

## Domains

| Page | Topic |
|---|---|
| [agent-profiles-and-handoff.md](domains/agent-profiles-and-handoff.md) | Named agent launch presets and the handoff of a task between agents |
| [agent-skill-completion.md](domains/agent-skill-completion.md) | Agent Skill completion in prompts |
| [agent-state.md](domains/agent-state.md) | Agent detection, agent runtime state, and the Agents View |
| [appearance.md](domains/appearance.md) | App appearance and the terminal theme |
| [cli.md](domains/cli.md) | The `codans` CLI and its RPC contract |
| [command-palette.md](domains/command-palette.md) | The command palette |
| [command-queue.md](domains/command-queue.md) | Queued and scheduled commands for a pane |
| [editor-integration.md](domains/editor-integration.md) | Opening a Worktree in an external tool |
| [environment.md](domains/environment.md) | Build channels, paths, environment variables, and command launch |
| [git-diff-viewer.md](domains/git-diff-viewer.md) | The read-only diff window |
| [git-platform.md](domains/git-platform.md) | GitHub and GitLab pull request data and actions |
| [keyboard-shortcuts.md](domains/keyboard-shortcuts.md) | The shortcut registry, conflicts, and persistence |
| [main-window.md](domains/main-window.md) | The single main window: sidebar, header, and tab bar |
| [notifications.md](domains/notifications.md) | The notification inbox, badges, and system banners |
| [pane-shell-integration.md](domains/pane-shell-integration.md) | How a pane starts its shell and its session daemon |
| [project-commands.md](domains/project-commands.md) | Run commands, command suggestions, and command icons |
| [project-tags.md](domains/project-tags.md) | Project tags |
| [remote-projects.md](domains/remote-projects.md) | Projects on a Host over SSH |
| [settings.md](domains/settings.md) | The Settings window and `settings.json` |
| [terminal-runtime.md](domains/terminal-runtime.md) | Terminal action routing and surface reclaim |
| [updates-and-release.md](domains/updates-and-release.md) | Update channels and the release pipeline |
| [workflow.md](domains/workflow.md) | Multi-agent workflows |
| [workspace.md](domains/workspace.md) | Workspaces and workspace groups |
| [worktree.md](domains/worktree.md) | The Worktree lifecycle, ordering, status, and processes |

## Conventions

Maintain these documents with the `document` skill. The rules below are the
ones a reader also needs.

- **One owner for each fact.** A parent page explains a relationship and links
  the page that owns the detail. Do not copy.
- **Current state, present tense.** Describe the code on the branch. Do not
  narrate how it got there: no history, dates, ticket ids, or progress. Git
  history and the CHANGELOG hold that.
- **Availability by user entry point.** A symbol in the code does not make a
  feature live. A domain page describes a capability as `Available`
  (implemented, with a reachable entry point) or `Hidden` (implemented, but the
  entry point is hidden or unwired). A capability without a working
  implementation is not in a domain page. It stays in its ticket.
- **Decisions go to `adrs/`.** A domain page states rules and links the record
  that gives the reason. Record a decision when a reader without the reason
  could make a harmful change. A record has a status: `Proposed`, `Accepted`,
  or `Superseded`. A new record replaces an old one; link both directions.
- **Mark a known difference.** When the code does not follow an approved rule,
  the page states what the code does and marks the difference. It does not
  change the rule to fit the code.
- **Historical records stay as written.** In `adrs/` and `lessons-learned/`,
  update only status and links.
- **English.** Use the terms of the glossary. Keep UI labels and identifiers
  as they are in the code.
- **Reachable.** Link each new page from this file.
