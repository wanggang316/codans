# Product Spec: Main-Window UI Redesign

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-20

## Summary

Redesign codans's main window into a two-column layout: a left **Sidebar** that lists Projects and their Worktrees and pins a Space switcher at the bottom, and a right **Detail** area with a Header row above the terminal showing the current branch, a notification bell, an "Open in external tool" picker, and a git-viewer toggle. The terminal itself (Tab bar + split Panes) stays as it is. This spec describes observable behavior and requirements only — implementation choices are left to the follow-up design phase.

## Layout Overview

```
┌───────────────────────┬──────────────────────────────────────────────────────┐
│                       │ Header                                               │
│ + Add Project    [⋯]  │ ┌─────────────┬────────────────────────┬───────────┐ │
│                       │ │ ⎇ branch    │                        │ 🔔 ↗▾ 📖  │ │
│ ▼ Project A   [+] [⋯] │ └─────────────┴────────────────────────┴───────────┘ │
│    ● main             │ ┌──────────────────────────────────────────────────┐ │
│    ○ feature/login    │ │ Tab 1   Tab 2   Tab 3   +                        │ │
│    ○ fix/crash        │ ├──────────────────────────────────────────────────┤ │
│                       │ │                                                  │ │
│ ▼ Project B   [+] [⋯] │ │                   Terminal Panes                 │ │
│    ● main             │ │               (split horizontal/vertical)         │ │
│                       │ │                                                  │ │
│ ▶ Project C           │ │                                                  │ │
│                       │ │                                                  │ │
│                       │ └──────────────────────────────────────────────────┘ │
│                       │                                                      │
│─────────────────────  │                                                      │
│ 🗂  MySpace       ⌄   │                                                      │
└───────────────────────┴──────────────────────────────────────────────────────┘
   Sidebar (leading)                     Detail (trailing)
```

Legend: `●` active Worktree, `○` inactive Worktree, `[+]` hover-only add, `[⋯]` options menu, `⌄` opens popover.

## User Stories

- As a multi-project developer, I want to see all Projects and Worktrees of my active Space in a single tree so that I can switch worktrees without digging through menus.
- As a user juggling several contexts (work / side projects / experiments), I want a Space switcher pinned at the bottom of the sidebar so that I always know which Space I'm in and can switch with one click.
- As a user returning to a Space, I want the previously active Worktree and its open Tabs/Panes restored so that switching feels like walking back into the same room.
- As a developer driving multiple worktrees, I want an always-visible current-branch label at the top of the detail area so that I never forget which branch my terminal is in.
- As a user who runs agents in terminals, I want a notification bell in the Header with an unread badge so that I see completed / blocked-on-input runs without polling the sidebar.
- As a user who jumps between terminal and editor, I want a one-click "Open in …" button in the Header with a picker for common editors so that I can hand a worktree off to my editor without copying the path.
- As a user who added an on-disk git repo elsewhere, I want an inline entry point on the sidebar to add a Project or a Worktree without leaving the window.

## Sidebar in Detail

```
┌──────────────────────────┐
│ + Add Project      [⋯]   │ ← sidebar toolbar
├──────────────────────────┤
│ ▼ Project A   [+] [⋯]    │ ← Project section header
│    ● main           ●    │ ← active Worktree (filled dot)
│    ○ feature/login       │   trailing dot = unread notification
│    ○ fix/crash       ●   │
│                          │
│ ▼ Project B   [+] [⋯]    │
│    ● main                │
│                          │
│ ▶ Project C              │ ← collapsed
│                          │
│                          │
├──────────────────────────┤
│ 🗂  MySpace         ⌄    │ ← Space footer (always visible)
└──────────────────────────┘
```

Tapping the Space footer opens a popover:

```
                ┌────────────────────┐
                │ ✓ MySpace          │
                │   Work             │
                │   Side Projects    │
                │   Experiments      │
                │────────────────────│
                │ +  New Space       │
                └────────────────────┘
                          ▲
┌──────────────────────────┐
│ 🗂  MySpace         ⌄    │
└──────────────────────────┘
```

## Header in Detail

```
┌─────────────────────────────────────────────────────────────────┐
│  ⎇  feature/login                    🔔 3    ↗ Open in ▾    📖 │
└─────────────────────────────────────────────────────────────────┘
   └── read-only branch name           │        │               │
                                       │        │               └─ toggle git viewer
                                       │        └─ split button + picker caret
                                       └─ notification bell with unread badge
```

Bell popover:

```
                          ┌─────────────────────────────────┐
                          │ Notifications    [Dismiss all]  │
                          │─────────────────────────────────│
                          │ Project A                       │
                          │   feature/login                 │
                          │     ↳ Claude finished           │
                          │   fix/crash                     │
                          │     ↳ Agent blocked on input    │
                          │ Project B                       │
                          │   main                          │
                          │     ↳ Codex completed           │
                          └─────────────────────────────────┘
                                        ▲
                                       🔔 3
```

"Open in …" picker (caret of the split button):

```
                                 ┌─────────────────────┐
                                 │ VS Code       ⌘E    │
                                 │ Cursor    (not found)│ ← disabled
                                 │ Zed                 │
                                 │ Xcode               │
                                 │ Sublime             │
                                 │─────────────────────│
                                 │ Reveal in Finder    │
                                 │─────────────────────│
                                 │ + Custom editors…   │
                                 └─────────────────────┘
                                            ▲
                                       ↗ Open in ▾
```

## Requirements

### Must Have

- [ ] Two-column layout: Sidebar on the left, Detail on the right. No persistent third column.
- [ ] Sidebar body renders the active Space's Projects as collapsible sections; each section shows the Project's Worktrees as rows underneath.
- [ ] Empty-Space state shows a placeholder message and an "Add Project" action.
- [ ] Space footer is pinned at the bottom of the Sidebar and is always visible. It shows the active Space's name and a disclosure indicator.
- [ ] Tapping the Space footer opens a popover listing every Space. The currently active Space is visually marked. Clicking another Space switches the active Space. The popover includes a "+ New Space" row at the bottom.
- [ ] Switching Space remembers the per-Space last-active Worktree and the open Tabs/Panes. Returning to a Space restores that Worktree and its Tabs/Panes.
- [ ] Each Project section header shows, on hover, a `+` button that starts the "Add Worktree under this Project" flow, and a `⋯` options menu (rename Project, remove Project, …). The `+` must be wired to a stub action even if the full flow isn't implemented yet.
- [ ] Each Worktree row has a right-click context menu with at minimum: Remove Worktree, Reveal in Finder, Open in (default editor).
- [ ] The Sidebar toolbar has an "Add Project" button at the top (the same entry point surfaced in the Sidebar empty state).
- [ ] There is no sidebar mode toggle (Hierarchy ↔ Inbox). Notifications are only reachable from the Header bell.
- [ ] The Detail area renders a Header row above the terminal Tab bar.
- [ ] The Header left shows a read-only branch-name label for the active Worktree (git-branch icon + branch name).
- [ ] The Header right shows, in order: a notification bell with an unread badge; an "Open in …" split button; a Git Viewer toggle.
- [ ] The notification bell popover lists unread notifications grouped by Worktree. Clicking a notification selects that Worktree and dismisses the badge for it. A "Dismiss all" action is present.
- [ ] The "Open in …" primary action opens the current Worktree in the default editor (or Finder if no default is set). The caret opens a picker.
- [ ] The picker lists six built-in editor choices (VS Code, Cursor, Zed, Xcode, Sublime, Finder) plus any user-defined custom editors. Editors that are not installed are shown disabled with an explanatory tooltip. Finder is always enabled.
- [ ] The Git Viewer toggle shows or hides a git diff/history overlay on the right side of the Detail area without shrinking the terminal below a usable width. Overlay visibility is remembered per Worktree.
- [ ] The terminal Tab bar and split Panes below the Header behave as they do today; no regressions.
- [ ] Selecting a Worktree with no active Tab shows an empty-state placeholder and a "New Tab" button.

### Should Have

- [ ] Unread notification dots propagate up the tree: a Worktree row with unread notifications shows a trailing dot; its parent Project section header aggregates those dots into a single indicator.
- [ ] A keyboard shortcut opens the Space switcher popover.
- [ ] A keyboard shortcut toggles the Git Viewer overlay.
- [ ] A keyboard shortcut triggers the "Open in default editor" primary action.

### Could Have

- [ ] Drag-and-drop reordering of Worktrees within a Project section.
- [ ] A Header center slot for a status toast (PR checks / CI status).
- [ ] A filter field at the top of the Sidebar for large Space/Project lists.

### Won't Have (this iteration)

- Editing the branch (rename / checkout / switch) from the Header. The branch label is read-only.
- A third persistent column for an inspector. The git viewer appears as an overlay, not a column.
- The full sheets/flows behind the sidebar entry points — "Add Project" and "Add Worktree under this Project" show their entry points in the UI, but the sheets themselves are out of scope.
- A gear / settings button in this chrome. Settings stays reachable through existing paths.
- Any in-app branch list or checkout picker.

## Acceptance Criteria

- Given multiple Spaces exist, when the user taps the Sidebar footer, then a popover appears listing every Space with the active one visually marked and a "+ New Space" row at the bottom.
- Given the user is in Space A viewing Worktree X with two Tabs open, when they switch to Space B and then back to A, then Worktree X is re-selected and its two Tabs are restored.
- Given the active Space has at least one Project, when the Sidebar renders, then each Project appears as a section header with its Worktrees listed as child rows beneath it.
- Given the user hovers a Project section header, when hover is sustained, then a `+` button appears on the right side of the header and stays visible until the pointer leaves.
- Given the user right-clicks a Worktree row, when the context menu appears, then it includes at minimum: Remove Worktree, Reveal in Finder, Open in (default editor).
- Given a Worktree is selected, when the Detail area renders, then a Header row is visible above the terminal Tab bar displaying a git-branch icon and the current branch name as a read-only label.
- Given there is at least one unread notification, when the Detail area renders, then the Header bell shows an unread count badge. When the user opens the bell popover and clicks a notification, then the app selects that notification's Worktree and the badge decrements accordingly.
- Given the user has VS Code installed but not Cursor, when they open the "Open in …" picker, then VS Code is enabled and Cursor is disabled with a tooltip explaining why. Finder is always enabled and, when clicked, opens Finder rooted at the active Worktree's path.
- Given the Git Viewer toggle is off, when the user taps it, then the git diff/history viewer appears as a right-side overlay on top of the Detail area without shrinking the terminal below a usable width. Tapping again hides it. The visibility state persists per Worktree.
- Given the previous build shipped a sidebar mode toggle (Hierarchy ↔ Inbox), when this redesign ships, then that toggle is gone and opening the bell popover is the only way to see notifications.

## Open Questions

None blocking. Q1 / Q2 / Q3 resolved during requirements gathering:

- Branch-name label is read-only.
- External-tool control is a split button with a caret picker.
- Switching Space restores the per-Space last-active Worktree along with its Tabs/Panes.

Deferred to the design phase:

- Exact keyboard shortcuts for the Should-have items.
- Per-Space last-active-Worktree persistence details.
- Git Viewer overlay presentation details.
- Unread-dot aggregation rules (read-mark propagation, debounce).
