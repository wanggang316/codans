<p align="center">
  <img src="apps/website/public/logo.png" alt="Codans" width="120" height="120" />
</p>

<h1 align="center">Codans</h1>

<p align="center">
  <strong>Run your coding agents in parallel, in one window.</strong>
</p>

<p align="center">
  <a href="https://codans.dev">Website</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="https://github.com/wanggang316/codans/releases">Releases</a>
</p>

<p align="center">
  <img src="apps/website/public/shots/hero-palette-1280.webp" alt="The Codans window with the command palette open: a sidebar of projects and worktrees, the Agents View, and Claude Code beside a dev server." width="900" />
</p>

Codans is a native macOS terminal for people who work through coding agents. It gives every task a worktree, every agent a pane, and shows you which ones are working and which ones need you.

## Features

- **Agent-first.** The Agents View shows every agent in every project with its live state. Start an agent with its worktree in one step, queue prompts for it, resume old sessions, and get a notification when it asks or finishes.
- **Many worktrees in parallel.** Each task has its own worktree, tabs, and panes. The sidebar shows the diff size, pull request, running commands, and unread bells of each one. The app is optimized for many terminals: memory stays low.
- **Pull requests.** Follow checks, merge, mark ready, and rerun failed checks for GitHub and GitLab, through the `gh` and `glab` CLIs that you are already logged in to.
- **Workspaces and remote projects.** Work on several repositories in one workspace like a monorepo, and on projects on another machine over SSH.
- **A CLI and an Agent Skill.** Everything in the window is a `codans` command, so agents can create worktrees, start other agents, and read their output.
- **Quick actions.** A command palette, project commands on the Run button, a shortcut for every action, and one key to open a worktree in your editor.
- **Native.** Built on Ghostty, with every Ghostty theme built in. Sessions keep running when you quit the app.

## Install

```bash
brew install --cask wanggang316/tap/codans
```

The cask installs `Codans.app` into `/Applications` and symlinks the embedded `codans` CLI into Homebrew's `bin`. Subsequent updates flow through the in-app Sparkle updater; `brew upgrade --cask codans` also picks up new stable releases.

## Running Codans

Requires macOS **14 (Sonoma) or later**. Xcode and mise are only needed to build
from source.

1. Open Codans and add a project directory from the sidebar.
2. Select its root worktree, or create a worktree for a separate line of work.
3. Run a coding agent in the terminal; use tabs and split panes for parallel tasks.

For CLI usage, see the [Agent Skill](skills/codans-cli/SKILL.md).

## Build from Source

### Development requirements

- Xcode **26 or 27** (pinned via `apps/mac/Tuist.swift`)
- [`mise`](https://mise.jdx.dev/) for tool version pinning (`tuist`, `zig`, `swiftlint`, `xcbeautify`, `xcsift`)

### Generate, build, and run

```bash
# One-time per worktree
mise trust . apps/mac
make bootstrap            # init submodules (ghostty, git-wt) + mise install

# Generate + build + run
make mac-generate         # tuist install + tuist generate (builds Ghostty xcframework)
make mac-build            # build Codans.app + codans CLI
make mac-run-app          # build + open the app
```

> First-time Ghostty build is ~3.9 GB / ~20 min. In additional worktrees, symlink the cache:
> `ln -s <main>/apps/mac/.build/ghostty apps/mac/.build/ghostty`

### Development commands

| Command | Description |
|---|---|
| `make bootstrap` | Init submodules + `mise install` |
| `make mac-generate` | Generate `codans.xcworkspace` from Tuist |
| `make mac-build` | Build the Mac app + `codans` CLI |
| `make mac-run-app` | Build and launch `Codans.app` |
| `make mac-lint` | Run `swiftlint --quiet` |
| `make mac-check` | `swift-format` in-place + lint |
| `make mac-test` | Run the Codans, CodansCore, and CodansKit test schemes |
| `make mac-release` | Archive → notarize → DMG → staple |
| `make help` | Full target list |

The top-level `Makefile` delegates every `mac-*` target to `apps/mac/Makefile`.

## Documentation

All project knowledge lives in [`docs/`](docs/):

- [Architecture](docs/architecture.md) — domains, layers, dependency rules
- [Product spec](docs/product-spec.md) — what the product is
- [Design docs](docs/design-docs/) — feature and system designs

Agent-facing entry point: [`AGENTS.md`](AGENTS.md) (also exposed as `CLAUDE.md`).

## License

Codans is open source under the [MIT License](LICENSE).
