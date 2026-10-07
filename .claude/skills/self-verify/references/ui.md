# Codans UI Verification

Read this before a scenario that drives or checks native UI. The driver is `scripts/sv-tool.swift`, wrapped by
the `sv_*` functions in `scripts/helpers.sh`. Its header lists every command.

## Preflight

```bash
sv_tool preflight   # exit 0 READY, exit 2 SKIPPED with reasons
```

Accessibility trust belongs to the app that runs the shell (the terminal or the codans pane host); screen
recording is needed only for screenshots. On `SKIPPED`, report the UI scenario as `SKIPPED`. Do not open System
Settings or ask for permission during a run.

## Observe, Act, Observe Again

1. Find the target in a fresh tree: `sv_tree | grep -n <word>`, or `sv_tree --window <title>` for one window.
2. Act once: `sv_press`, `sv_set_value`, `sv_select_row`, or `sv_menu`.
3. Wait for a concrete result: `sv_wait <role> <label> [--gone]`.
4. Assert the new label, value, selection, window title, or `codans_debug` JSON.

Each tree line is `role (subrole) "title/description" = "value" #identifier [state] {actions} @x,y wxh`.
Unlabelled layout groups are hidden. Frames are global, top-left origin.

Address elements by `#identifier` when one exists: labels often carry state. The branch button reads
`Branch bugfix/menu` on one branch and `Default branch` on the default branch; its identifier
`worktree_header.branch_button` stays. Labels are still the right assertion for state ("Hide agents view" flips
to "Show agents view"). Find all identifiers with
`grep -rho 'accessibilityIdentifier("[^"]*' apps/mac/codans | sort -u`.

Check the role in the tree before you wait on it: a SwiftUI `Menu` is an `AXMenuButton`, not an `AXButton`, and a
wait on the wrong role times out as if the control never appeared.

`sv_press` refuses an element without an `AXPress` action. AX returns success for a press on a static text or an
`onTapGesture` view and nothing happens, so a press that "worked" without a state change is a known trap.

## Windows

- A new window can become main. To scope a check to one window, use `sv_tree --window <title>` or
  `sv_main_window <title>`; neither activates the app.
- Settings opens with `sv_menu Codans "Settings…"`. Its window title follows the selected pane ("General",
  "Notifications", "Global Commands"), and it opens at the same origin as Gump's own Settings window, so never
  find it by screen position.
- Close a window with `sv_close_window <title>`. Do not close the main window: it leaves the app headless.

## Codans Surfaces

### Toolbar

| Control | Address | Notes |
|---|---|---|
| Add menu | `AXMenuButton Add` (`#plus`) | |
| History | `AXButton Back` / `Forward` in `#header.history` | segments |
| Branch | `AXButton worktree_header.branch_button` | opens the branch popover |
| Processes | `AXButton status.processes` | value is "N running"; opens a popover with "Processes" |
| Notifications | `AXButton "Notifications: no unread"` | label carries the unread count |
| Agent, Run, Open in | split buttons | see below |

Split buttons are an `AXPopUpButton` (Agent, Open in) or a labelled `AXGroup` (Run) with two `AXSegment`
children. The first segment runs the primary action; the second is the unlabelled chevron. Address the chevron
with an empty label inside the control:

```bash
sv_press AXMenuButton "" --within "Open in Cursor"   # Agent: --within "Start Claude Code"
sv_press AXButton "" --within Run                    # can exit 3: see below
sv_wait AXMenuItem Zed --timeout 3000
sv_cancel_menu                                       # pressing the chevron again does not close it
```

After you pick a menu item, wait for it to be gone (`sv_wait AXMenuItem <item> --gone`) before the next press:
a press while the previous menu is still closing can be dropped.

A press that opens a menu can return only after the menu closes; AX then times out and `sv_press` exits 3
("uncertain"). The menu is usually open: observe with `sv_wait AXMenuItem ...` before you press again.

`--near <label>` scopes to the parent of the labelled element, for a chevron that is a sibling of a labelled
segment. Never press the primary segment of "Start Claude Code", and never pick an "Open in" item: they launch a
real agent or editor.

### Sidebar and Agents View

- The project tree is an `AXOutline "Sidebar"`; worktree rows hold an `AXStaticText` with the branch name. Select a
  worktree with `codans_debug pane focus <pane>`, not with AX: text in a row has no press. (`worktree switch`
  only records the selection; it does not move the sidebar.)
- The Agents View toggle is `#agentState.sidebarToggle`. Its label flips between "Hide agents view" and "Show agents
  view"; assert the flip.

### Branch Popover

- Open: `sv_press AXButton worktree_header.branch_button`; wait for `AXTextField "Filter branches"`.
- Filter: `sv_set_value AXTextField "Filter branches" <text>`; rows are `AXGroup` with
  `#branch_switcher.branch_row.<local|remote>.<name>`.
- The row body is not tappable. Its actions sit in a hover-only "Branch actions" menu. Switch a branch with a
  guarded sequence:

```bash
sv_physical_begin
read -r x y <<<"$(sv_center AXStaticText bugfix/menu)"
sv_hover "$x" "$y"
sv_wait AXMenuButton "Branch actions" --timeout 2000
sv_press AXMenuButton "Branch actions"
sv_press AXMenuItem Switch
sv_physical_end
codans_debug tree --json | jq -r '.data.projects[0].worktrees[0].branch'   # assert
```

- Close: press the branch button again and wait for the field to be gone.

### Settings

- Navigate with `sv_select_row <pane name>` (it sets `AXSelectedRows`; a press on the row text does nothing).
  Assert the window title, then a heading in the detail (`sv_find AXHeading "In-app"`).
- Switches are `AXCheckBox (AXSwitch)` with no label of their own (their value is "0" or "1"); the row text is
  the `AXStaticText` before them. Pair them with `--after`:
  `sv_press AXCheckBox "*" --after "Show Dock badge"`, then assert `sv_get AXCheckBox "*" --after "Show Dock
  badge"` and `settings.json`. The metadata repair below (give the switch its row label) removes the need.
- Popups are `AXPopUpButton` labelled only by their current value: `sv_press AXPopUpButton Auto`, then
  `sv_press AXMenuItem Always`. Assert the new value and the scratch `settings.json` (`$SELF_VERIFY_DIR/conf`).
- Settings controls nest deeply; `sv-tool` walks 80 levels, so deep popup items are found.
- Restore every setting the scenario changed.

### Terminal Panes

A pane is `AXTextField "Terminal pane"` whose value is the visible text. Do not type into it or read terminal
state through AX or pixels: use `codans_debug pane send` / `capture` / `read`.

## Physical Input

Use it only for tap gestures and hover-revealed controls. `sv_click` and `sv_hover`:

- refuse a point outside every instance window, before any activation;
- activate the instance by PID and raise the window under the point;
- refuse unless the instance owns the topmost visible window under the point (popovers and menus included);
- `sv_click` gives focus and cursor back unless it runs inside `sv_physical_begin` / `sv_physical_end`.

Wrap a multi-step sequence in `sv_physical_begin` / `sv_physical_end` so focus goes back once. A transient popover
can close when the app loses or gains activation: open it inside the physical block when the next step is
physical. After an uncertain result, observe the state before you try again; never repeat blindly.

## Known Accessibility Gaps

Fix these with the evolution rules below when a scenario needs them; until then expect the workaround.

| Surface | Gap | Workaround |
|---|---|---|
| Branch popover row | label says "Switch to branch X" but the row has no action; actions are hover-only | hover sequence above |
| Branch popover field | carries the popover's `#branch_switcher.popover`, not `#branch_switcher.search` | address by label "Filter branches" |
| Branch button | label is "Default branch" on the default branch, without the name | use the identifier; read the branch from the CLI |
| Settings switches | no accessible label | `--after "<row text>"` with label `"*"` |

## Evolve the Verification Surface

Treat friction in a run as a finding. First restore the scenario, then classify the owner:

1. Codans accessibility metadata.
2. `sv-tool` discovery, scoping, or delivery.
3. macOS permission, focus, timing, or framework limit.

An explicit invocation of this skill allows a narrow codans repair, unless the request is read-only. Repair only
when all of these are true:

- Fresh trees from the instance PID reproduce the missing or wrong semantic state.
- The source makes the intended label, value, role, action, or identity clear.
- The change is limited to `accessibilityIdentifier`, label, value, traits, actions, or container metadata.
- Layout, control type, focus, window lifecycle, persisted data, and the visible action do not change.
- The same scenario proves the improvement after a rebuild and relaunch.

Use stable, non-localized identifiers that describe product meaning, not display text, indexes, or runtime data.
Keep VoiceOver semantics true: do not add a selected state to a momentary button or flatten useful children.

For a repair: keep the before line, make the smallest change, rebuild, rerun the same scenario, keep the after
line, then update this file only for durable knowledge. Do not commit, push, or install anything without the
user's request.

Add this to the report of every UI scenario:

- `Friction`: what was hard, or `None`.
- `Ownership`: `Codans`, `sv-tool`, `macOS`, or `Unclear`.
- `Confidence`: `High`, `Medium`, or `Low`, with the decisive evidence.
- `Change`: source and skill edits, or `None`.
- `Before / After`: tree lines when a repair was made.
- `Follow-up`: open recommendation, or `None`.

## Why Not agent-ctrl

`agent-ctrl` 0.1.4 was evaluated on this app. Its snapshot stops at depth 12, so Settings popup items are
missing; its physical fallback calls `AXRaise`, which codans windows do not support, and fails after it has
already activated the instance; it reports `ax-press` success on static text; and a fresh session without a
target pins to the frontmost app, which can be Gump's. `sv-tool` keeps the same discipline without a
third-party binary or install step.
