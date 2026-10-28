# codans

A macOS app that hosts terminals for CLI-agent work and arranges them in a Project → Worktree → Pane → Tab hierarchy. This glossary is the canonical vocabulary for code, CLI, IPC, and docs.

## Language

### Hierarchy

**Project**:
A directory the user registered: a git repository, a plain folder, a Server (SSH) folder, or a Workspace.
_Avoid_: Repo, repository (that is the git object, not the row)

**Worktree**:
One checkout or synthetic directory root under a Project. It owns a layout of Panes.
_Avoid_: Branch, checkout (a Worktree is identified by its directory, not its branch)

**Pane**:
A leaf of a Worktree's split tree. It holds an ordered strip of Tabs with one selected Tab, and is never empty.
_Avoid_: Card, split, panel, terminal

**Tab**:
One slot in a Pane's strip. It carries the chip attributes (title, color, icon) and exactly one Content.
_Avoid_: Session, terminal, chip (the chip is the Tab's rendering)

**Content**:
What runs inside a Tab: a stable identity (ContentID) plus a kind-specific state. The terminal kind is the only kind today.
_Avoid_: Session, pane, surface

**Surface**:
The libghostty rendering surface of a terminal Content. One terminal Content has one Surface.
_Avoid_: View, terminal, pane

### Layout

**Split tree**:
The binary tree of horizontal and vertical splits whose leaves are a Worktree's Panes.
_Avoid_: Layout tree, grid

**Focused Pane**:
The one Pane in a Worktree that receives keyboard input and Tab-level shortcuts.
_Avoid_: Active pane, current split

**Selected Tab**:
The Tab a Pane shows. Each Pane has exactly one.
_Avoid_: Active tab, current tab

**Zoom**:
A Pane state in which it fills the Worktree's layout area and the other Panes are hidden.
_Avoid_: Maximize, fullscreen
