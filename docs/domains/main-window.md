# Main Window

Codans has one main window. It shows the catalog as a sidebar on the left and the selected Worktree on the right. The right column has three parts: the header (the SwiftUI window toolbar), the tab bar, and the Pane area. This page covers the window, the sidebar, the header with its status slot, and the tab bar.

Availability: Available. Hidden: the Tag filter button of the sidebar footer, and the workflow capsule of the header (`HeaderWorkflowGroup` exists, but the toolbar does not mount it; workflows start from the command palette).

## Scope and ownership

| Topic | Owner |
|---|---|
| Worktree rows: lifecycle, order, branch switcher | [Worktree](worktree.md) |
| Pull Request badge content and the Pull Request form of the status slot | [Git Platform](git-platform.md) |
| Agents View panel at the bottom of the sidebar | [Agent State](agent-state.md) |
| Unread state, the bell on rows, the Unread filter semantics | [Notifications](notifications.md) |
| Tag model and Tag filter | [Project Tags](project-tags.md) |
| Host records and Remote Project transport | [Remote Projects](remote-projects.md) |
| Workspace groups and member checkouts | [Workspace](workspace.md) |
| Pane layout, splits, terminal surfaces, Pane title | [Terminal Runtime](terminal-runtime.md) |
| Run button and its menu | [Project Commands](project-commands.md) |
| Open button and default editor | [Editor Integration](editor-integration.md) |
| New Agent dialog | [Agent Profiles and Hand-off](agent-profiles-and-handoff.md) |
| Default chords | [Keyboard Shortcuts](keyboard-shortcuts.md) |

## Window regions

```
+-------------------+---------------------------------------------------------+
| update  +  toggle | Back/Fwd  identity  ·  New Agent  status slot  ·  Run Open |  <- toolbar
+-------------------+---------------------------------------------------------+
| filter bar        | branch switch error banner (only on error)              |
| Host              | [ tab ][ tab ][ tab ]       (only with 2 or more tabs)  |
|   Project         | +-----------------------------------------------------+ |
|     Worktree      | |  Pane cards (split tree of the selected Tab)        | |
| Agents View panel | |                                                     | |
| help  agents  gear| +-----------------------------------------------------+ |
+-------------------+---------------------------------------------------------+
```

The left part of the toolbar belongs to the sidebar column: the update reminder (only when a newer build exists), the Add Project menu, and the sidebar toggle. The sidebar visibility is in memory and starts visible.

## One window

- The main scene is `Window("Codans", id: "main")`, so there is exactly one main window. A click on the Dock icon brings it back; the system adds no "New Window" item. Settings is a separate window. One window means one owner of the terminal surfaces and of the selection.
- Closing the main window does not quit the app (`applicationShouldTerminateAfterLastWindowClosed` returns false). Panes keep running.
- **⌘W escalates.** In a Tab with more than one Pane, it closes the focused Pane. Else it closes the selected Tab. Only when the selected Worktree has no Tab does it close the window. AppKit's File ▸ Close owns ⌘W and SwiftUI cannot remove it, so `MainWindowCloseInterceptor` vetoes the close in `windowShouldClose` when the current event is the ⌘W key-down. The red close button and a click on File ▸ Close still close the window.
- **Quit.** `quitConfirmation` is `auto`, `always`, or `never`. `auto` asks only when a live Pane is busy: a running command, OSC 9;4 progress, or an agent in mid-task. `quitAction` (keep sessions running, or snapshot them) applies with or without the dialog; the dialog also offers Cancel. The disposition runs before the app terminates, and a re-entrancy guard stops a second pass. See [Settings](settings.md) and [Terminal Runtime](terminal-runtime.md).

## Sidebar

### Rows

The sidebar is an `NSOutlineView` (`SidebarOutline`, [ADR 0002](../adrs/0002-sidebar-outline-with-host-level.md)) with these rows:

- **Host rows**, only when at least one Project is not on This Mac. This Mac comes first, then the Hosts in Host list order. The decision reads all Projects, not the filtered ones, so a filter never adds or removes the level; a Host without a matching Project is hidden. Host rows cannot be selected. A click opens or closes them.
- **Project rows.** The row of a git Project cannot be selected; a click opens or closes it, and the main checkout is its first child. A Project without its own repository (a folder or a remote folder) has a row that stands for its root (`Project.rowWorktree`): the row is selectable and carries the busy, unread, and menu state of that Worktree, and it has no child for the root.
- **Worktree rows and pending rows** below a git Project ([Worktree](worktree.md)).
- **Workspace group rows** below a Workspace Project. A click on a group selects the row of the group directory ([Workspace](workspace.md)).
- A Project that failed to load shows a failure row.

### Data flow and selection

- **The view reads the catalog directly.** `HierarchySidebarView` reads `HierarchyManager.catalog` through `@Environment`. The catalog is not copied into reducer state. `HierarchySidebarFeature` holds only intent and transient UI state: pending rows, dialogs, sheets, and the last expansion toggle. Mutations go through `HierarchyClient`.
- The highlighted row is read live from the catalog, not from the `currentSelection` property, because the property arrives one render later and a cross-Project click would show the old row for one frame.
- A row click calls `selectProject` and then `selectWorktree`. Both are necessary: the selection reads the `selectedWorktreeID` of the selected Project.
- `RootFeature` follows `hierarchyClient.selectionChanges()`, which yields after the catalog has changed. Any flow that needs the previous selection must read it in the intent action, before the `HierarchyClient` call. In the stream handler the old state is already gone.
- ⌃1…⌃0 and ⌘⌃↑ / ⌘⌃↓ use one list, `Catalog.sidebarSelectionOrder`: the selectable rows on screen, after the filters. Rows in a collapsed Host or Project and rows of a failed Project are not in it.
- **Reveal** (command palette, notification, Agents View, the reveal-current-Worktree menu command) switches the filter to All when the active filter does not list the row, opens the Host, the Project (not for a row that is the Project row itself), and the Workspace group, shows the sidebar, and scrolls the row into view.

### Filters

The filter bar at the top has All, Remote, Workspace, PR, and Unread. The choice is saved in the catalog (`sidebarFilter`); an unknown value decodes as All. It intersects with the Tag filter, and the navigation chords use the same result.

- PR and Unread are live matches. Their sets come from app state (the Pull Request snapshots and the unread Worktrees), so the filtered list changes when the data changes, and the catalog does not.
- While PR or Unread is active, Worktree drag is disabled. Project drag stays available.
- The Unread button has "Mark All as Read" in its context menu.

### Order, drag, and disclosure

- The Project order is the order of `catalog.projects` ([ADR 0001](../adrs/0001-project-order-is-manual-only.md)). A drag moves the whole Project block, and a drop is valid only between Projects of the same Host. The drop resolves to "before or after visible Project X" and applies to the full array, so a drag works under every filter and hidden Projects keep their relative positions.
- The open state lives in the catalog only: `Project.isExpanded`, the expanded flag of a Workspace group, and `collapsedSidebarHosts`.
- **Only a user toggle animates** ([ADR 0007](../adrs/0007-sidebar-animates-user-expansion-only.md), [ADR 0008](../adrs/0008-sidebar-disclosure-animation-matches-the-list.md)). The reducer passes the intent to the outline in `expansionToggle`; the outline does not infer intent from a change of catalog state. Reveal, launch restore, filter changes, and CLI writes open and close at once. With Reduce Motion on, user toggles are also instant.

### Rendering rules

- **No filesystem query while rendering.** Rows find their Workspace membership in `WorkspaceMembershipIndex`, which `HierarchyManager` rebuilds only when catalog identity, path, or Workspace slot fields change. Command guards use the live path lookup instead.
- Agent activity is observed in the row accessory (`SidebarWorktreeActivityIcon`), not in the list builder, so an agent state change re-renders one icon and not the tree.

The footer holds the Help menu, the Agents View toggle, and Settings. There is no refresh button: "Refresh All Projects" is in the command palette.

## Header

The header is the window toolbar of the detail column (`WorktreeDetailView.worktreeToolbarContent`). Items, in order:

1. **Back / Forward** over the Worktree visit history (in memory).
2. **Identity**: the same icon as the sidebar row (unread replaces it with a bell), the branch line, and the Worktree and Project names. A click on the branch line opens the branch switcher ([Worktree](worktree.md)).
3. **New Agent**, which opens the New Agent dialog.
4. **Status slot** (below).
5. **Run** and **Open** split buttons.

Rules:

- **One toolbar declaration for both modes.** While a creation is in progress, the same slots show skeleton stand-ins, and New Agent stays live. If the two modes declared different item sets, `NSToolbar` would rebuild every item and the items would slide in from the leading edge. Change the content of a slot, not the item set.
- The toolbar shows no items for a failed creation, and for a selection whose rows were removed.
- The header does not open an editor itself. It sends a delegate action to `RootFeature`, which forwards to `EditorFeature`. The Open button label and the Open action must name the same tool; [Editor Integration](editor-integration.md) owns the resolution order.

### Status slot

The slot shows one form, by priority:

| Priority | Form | Condition |
|---|---|---|
| 1 | Toast | `StatusBarFeature.State.toast` is set |
| 2 | Pull Request | the Worktree has a Pull Request snapshot that is not closed |
| 3 | Idle | otherwise: local time, a time-of-day icon, the palette chord |

- The toast is the only reducer state of the slot; the other forms read data that other features own. All of it is in memory.
- `StatusToast` is `inProgress`, `success`, or `warning`; there is no error case, because a fatal error uses a sheet or a banner. `success` clears after 3 seconds, `warning` after 8; `inProgress` stays until it is replaced or dismissed.
- **Only `RootFeature` pushes toasts.** It maps the results of child features (editor open, run script, agent launch, Pull Request actions, hand-off, workflow start) to a toast. Child features do not send actions to the slot.
- Each push increments `sequence`. A clear timer clears the toast only when its sequence is still current, so a late timer cannot clear a newer toast.
- A narrow window gets a compact form, then nothing.

## Tab bar

- The bar shows only when the Worktree has two or more Tabs. With one Tab there is nothing to switch to; with none, the empty page offers New Tab and Resume Session.
- The view reads the Tabs from the catalog. `TabBarFeature` is stateless and forwards each action to `HierarchyClient`. Do not add a parallel tab state: Tabs belong to the Worktree in the catalog.
- **Chip content comes from one Pane**: the last focused Pane of the Tab, else the first. The title is the Tab name if `codans tab rename` set one, else the Pane title ([ADR 0009](../adrs/0009-agent-title-and-pane-title-follow-separate-standards.md)). The icon is `PaneGlyph`, the same as the Pane card header. There is no UI to rename, recolor, or change the icon of a Tab.
- The chip spinner shows a terminal busy signal (OSC 9;4 progress or a running command). A working agent shows its own spinner in the title, so the chip hides its spinner for it.
- A drag commits the new order once, on drop (`reorderTabs(orderedIDs:)`), not on each pointer move. Each move would save the catalog and make chips flicker at a midpoint.
- Bulk close (others, to the right, all) keeps `selectedTabID` on a Tab that exists.
- A Tab created from the UI opens its first Pane after a short delay, and after the selected Tab closes, the next Tab mounts its terminal late. A terminal surface that enters the window stalls the compositor for a few frames, which would stutter the tab animation. A plain Tab switch is not delayed.
- The bar copies the macOS window tab bar by measurement (`TabBarMetrics`, `TabBarColors`). When Tabs overflow, edge Tabs stack into thin strips (`TabStackLayout`); a selection change does not scroll.
- **Hover card.** Hovering a chip shows its full title and the process the Tab runs, from the Worktree process registry. The first card waits a short delay; moving to another chip swaps it at once. The card is a non-activating child panel that ignores the mouse, so it never takes focus from the terminal.

## Runtime-only state

Saved in the catalog: the filter, the Tag filter, the open state of Hosts, Projects, and Workspace groups, Tabs and their order, and the selection. In memory only: pending rows, the visit history, the sidebar visibility, the status toast, the per-Pane busy sets, and the last focused Pane per Tab. Busy sets are not saved because a saved spinner would still turn after a restart; every teardown path (close Pane, close Tab, Worktree teardown) clears its entries.

## Traps

- A chip placed inside the scroll content disappears when the window gets narrow, because SwiftUI culls views by layout slot. The chips are laid out in viewport coordinates over an empty scroll spacer. Moving chips with `.offset` alone leaves hover, click, and drag on the old positions.
- `@Observable` tracking does not pass through a TCA client closure. A view that must update on a busy change reads `HierarchyManager` through `@Environment`, not through a `HierarchyClient` result.
- Do not put an accessibility label on text with `.textSelection(.enabled)`: an AX client then recurses until the stack overflows. Put the label on a plain container ([lesson learned](../lessons-learned/2026-11-09-ax-label-on-selectable-text-recursed.md)).
- Archive and Delete Worktree chords work in the whole window, not only in the sidebar ([ADR 0011](../adrs/0011-worktree-archive-and-delete-chords-are-window-wide.md)).

## Shape of the implementation

```
 ContentView (NavigationSplitView)
   ├── HierarchySidebarView ── reads ──► HierarchyManager.catalog (@Observable)
   │     HierarchySidebarFeature ── HierarchyClient ──► HierarchyManager
   └── WorktreeDetailView: toolbar (WorktreeHeader, StatusBar), TabBarView, Pane area
 RootFeature: selection stream, reveal, toasts, editor and run effects
```

Views read the catalog; reducers hold intent and transient state; `HierarchyManager` is the single owner of structure and runtime busy state. `RootFeature` joins the child features and owns every cross-feature effect.
