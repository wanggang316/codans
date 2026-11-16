# Notifications

A notification brings the user back to the one Pane that needs them: an agent that waits for input, or a long task that ended. This domain turns runtime events into inbox entries, unread indicators on the four levels, the Dock badge, and macOS banners. It keeps an inbox across restarts, and a click on a banner takes the user to the source Pane.

Availability: Available. Hidden: the `inAppEnabled` and `moveNotifiedWorktreeToTop` switches have no control in Settings; only `settings.json` changes them.

## Scope and ownership

| Topic | Owner |
|---|---|
| Agent runtime state, attention stops, the Agents View | [Agent State](agent-state.md) |
| Row order rules of a promoted Worktree | [Worktree](worktree.md) |
| Storage and decoding of the switches | [Settings](settings.md) |
| Shared bundle id: Debug and Release share system notifications | [Environment](environment.md) |
| When a workflow run asks for attention | [Workflow](workflow.md) |

**Relation to agent state.** The two domains are independent. Each reads the raw terminal signals for itself, and neither reads the output of the other. The only link: before delivery, notifications ask the agent state store whether the user already saw the attention stop of the Pane (see [Attention stops](agent-state.md#attention-stops)). Do not derive agent state from read state, and do not feed agent state into the interpreter.

## Sources

Detection reads only structured events that the runtime already emits. There is no scan of terminal output: a tool that emits none of these signals produces no notification.

| Signal | Entry | Kind |
|---|---|---|
| Desktop notification (OSC 9 and similar) | Its own title and body | `waitingForInput` if the text has "permission", "approval", "approve", or "input", or the title ends with `?`; else `taskFinished` |
| Terminal bell | "Pane bell" | `waitingForInput` |
| Command finished (OSC 133) | "Command finished" or "Command failed (exit N)" | `taskFinished` |
| Pane crashed | "Pane crashed" with the reason | `taskFinished` |
| Pane idle for 30 s or more, after it produced output | "Pane idle" | `taskFinished` |
| Workflow attention, end, or `notify` step | "Workflow · <name>" | `taskFinished` if the run completed; else `waitingForInput` |

A normal child exit gives no notification. A Pane that never produced output gives no idle notification.

A command-finished event is dropped when the setting is off, when the exit code is 130 or 143 (the user cancelled), when the command ran shorter than the threshold (default 10 s, Settings → Notifications), or when the user typed in that Pane in the last 3 seconds. Keystrokes reach the interpreter through a side channel (`PaneKeyboardActivityTracker`), not through `TerminalEvent` and not through the catalog: a keystroke must not cause a catalog save or a SwiftUI render.

> **Discrepancy:** the caption in Settings → Notifications says notifications are suppressed for 1 second after typing. The interpreter uses 3 seconds.

**Mute.** "Mute notifications" in the Pane context menu toggles the label `notifications:muted` in `Pane.labels`, which the catalog saves. The detector drops all events of a muted Pane before the gate. The `mute` section of the settings file is not read by any path.

## The path

```
TerminalEvent ──► NotificationDetector ── interpret ──► PaneAttentionInterpreter (pure)
   (engine)        source path, mute,                   (event, context) → cue | drop
                   focus, observed stop
                        │ Candidate
workflow engine ──────► ▼
                 NotificationCoordinator (gate)
                   │ source focused → drop all
     ┌─────────────┼──────────────────┬───────────────────┐
     ▼             ▼                  ▼                   ▼
  inbox        Dock badge        macOS banner      promote Worktree
 (inAppEnabled) (inApp + dock)   (system + auth)   (first unread)
     │
     ▼
 RollupIndex ──► sidebar, tab bar, header indicators; Unread filter
```

Detection and policy are separate. `PaneAttentionInterpreter` (in `CodansCore`) is a pure function: all its inputs, including the clock and the keystroke times, come in a context value. `NotificationDetector` finds the source path in the catalog, applies mute, and decides whether the source is in view. `NotificationCoordinator` is the single gate: every candidate, from the detector or from the workflow engine, goes through it, and no other path posts a banner. Keep new policy in the coordinator and new classification in the interpreter.

## The gate

The coordinator reads the live settings and the cached authorization at decision time, so a switch that changes takes effect on the next event.

1. **Source in view.** If the source Pane is in view, the candidate is dropped with no inbox entry, no badge, and no banner. A Pane is in view when it has keyboard focus, or when it is the focused Pane of the selected Tab while the app is active, or when the agent state store reports that the user already saw the current attention stop of the Pane. The last test does not apply to a crash, which is a new event. Agents often send their reminder some time after they stop, so focus at post time alone misses a look that already happened.
2. **Inbox.** If `inAppEnabled` is on, the entry is appended.
3. **Dock badge.** It shows the total unread count when `inAppEnabled` and `dockBadgeEnabled` are both on, else nothing. It is recomputed from the inbox on each change, not counted in the gate.
4. **Banner.** If `systemEnabled` is on and macOS authorization is `authorized`, a banner is posted, with sound when `soundEnabled` is on. The banner and the inbox are independent: banners only, inbox only, both, or neither are all valid.
5. **Promote.** If `moveNotifiedWorktreeToTop` is on and the unread count of the source Worktree went from 0 to more than 0, the Worktree moves to the top of its unpinned rows. The coordinator counts unread entries in the inbox before and after the append, so a merged duplicate or an eviction does not count as a new first unread. A pinned Worktree does not move, and the Worktree does not move back when its unread count returns to 0.

Separately, each emitted cue marks its Project as active for the sidebar sort, before the gate and also when the gate drops it.

## Authorization and banners

The app never asks for authorization by itself, not at launch and not on the first notification. In Settings → Notifications, with "Show macOS banners" on, a status row shows **Request…** when the status is `notDetermined` and **Open System Settings…** when it is `denied`. Turning the switch on while macOS denies shows an alert, and the switch stays on: it records the intent of the user, not the system state. The app reads the status at launch and each time it becomes active.

The banner title is the entry title. The body is the entry body plus a line with the Project and Worktree names. Banners are grouped per Pane. The app delegate asks macOS to show banners and play sound also while the app is in front, because the gate already decided that the user does not see the source.

**The focus link.** Each banner carries `codans://focus?project=…&worktree=…&tab=…&pane=…` in its payload. The app registers no URL scheme: the app delegate reads the link only from the response to its own notification, and `RootFeature.focusHierarchyPath` selects Project, Worktree, Tab, and Pane in turn. It reads the live catalog again after each step and stops at the deepest level that still exists. It does not open an archived Worktree.

## The inbox

An `InboxEntry` holds a kind (`waitingForInput` or `taskFinished`), a title, a body, a creation time, a read time, and the source path as four raw IDs (Project, Worktree, Tab, Pane). Raw IDs, not references, because the catalog changes on its own: navigation resolves the path when the user acts.

`NotificationStore` holds the entries in memory, newest first, and saves them to `notifications.json` in the state directory of the channel (`~/.codans/state/` for Release; see [Environment](environment.md)) with a short debounce, and at quit.

- **Merge.** A new entry with the same Pane and kind as an entry less than 30 s old replaces that entry's text and time and keeps its read state.
- **Age and size.** Entries older than 7 days are removed at load. Above 500 entries, the oldest read entries go first, then the oldest unread.
- **Read.** When a Pane becomes the focused Pane of the selected Tab, its entries become read. This does not require the app to be active. "Mark All as Read" marks all. Entries of a Pane that is no longer visible (closed, or in an archived Worktree) become read; an unarchive does not restore them.
- **File format.** The file is `{ "version": 1, "entries": [...] }`; a bare array also loads. A file with a higher version, or a file that does not decode, moves to the backups directory and the inbox starts empty. After a higher-version move, one "Inbox reset" entry names the backup, once per backup file. If the load fails in another way, the inbox starts empty and does not save, so it does not overwrite a file it could not read.

There is no inbox list view, and the CLI does not read the inbox. The filtered sidebar answers "where".

## Unread indicators

`RollupIndex` derives the indicators from the unread entries and the visible state of the window. **Each unread entry shows at exactly one level: the deepest ancestor that the user cannot see.**

| Where the source is | Indicator |
|---|---|
| Project collapsed | Dot on the Project row |
| Project expanded, Worktree not selected | Bell on the Worktree row (and in the header label) |
| Worktree selected, Tab not selected | Dot on the Tab |
| Tab selected | None: the user already looks into the Tab |

A Worktree drawn as its Project's own row is on screen when the Project is collapsed, so it shows at the Worktree level on that row. A row hidden in a collapsed Workspace group shows on the group row. The index is computed from the live inbox and catalog on each change, not kept as a cached count: a catalog change alone, such as removing a Worktree, must update it. The project, worktree, and tab bell switches in Settings hide an indicator level; they do not change the inbox.

**Unread filter.** The bell item of the sidebar filter bar ("Unread", ⌘U "Show Unread Notifications") lists each Worktree that has an unread entry by its own `worktreeID`, without roll-up, and its Project. The item is orange while unread entries exist, and its context menu has "Mark All as Read". A selected row whose last entries become read stays in the list until the selection moves or a filter is selected again, so the row does not disappear under the pointer.

## Traps

- A tool that emits no OSC 9, bell, or OSC 133 is not covered. A shell without OSC 133 gives no command-finished events.
- Focus in the catalog marks entries read even while another app is in front, but it does not count as an observed attention stop in the agent state store.
- The source path of a Pane is cached while the Pane lives, so a crash event that arrives after the Pane left the catalog still resolves. That fallback has no mute state and no names for the banner.
- Debug and Release builds share the bundle id, so macOS shows their banners and authorization as one app. See [Environment](environment.md).
- A higher-version inbox file is moved, not deleted. If the move fails, the app still starts with an empty inbox.

## Shape of the implementation

`CodansCore/Notifications/` holds the value types and pure logic: `InboxEntry`, the merge and sweep rules, the file envelope, `PaneAttentionInterpreter`, and `RollupIndex`. `App/Features/Notifications/` holds the main-actor parts: the detector, the coordinator, the store, the macOS adapter (`OSNotifier`), the Dock badge, and the keystroke tracker. `AppState` wires them at launch and drains the engine event stream into the detector. Data flows one way: engine, detector, coordinator, then the store and the system; the views observe the store through `RollupIndexProvider`. The store knows nothing of the UI or the system, and the coordinator asks `HierarchyClient` to reorder; it does not change the catalog itself.
