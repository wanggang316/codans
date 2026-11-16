# Agent State

Users run coding agents (Claude Code, Codex, Pi, and others) in Panes across many Worktrees. The agent state domain answers two questions for each Pane: does an agent run here, and what is it doing now. It shows the answer in the Agents View panel at the bottom of the sidebar, and the CLI, the command queue, workflows, and the quit dialog read the same answer.

Availability: Available. Hidden: the popover variant of the agent list (`AgentStateView`), which no view mounts.

## Scope and ownership

This domain owns agent identification, the agent runtime state and its two sources, the agent title, and the Agents View panel. Neighbor topics:

| Topic | Owner |
|---|---|
| Notifications, unread state, the inbox | [Notifications](notifications.md) |
| Foreground process sampling, zmx daemons, passive watchers | [Terminal runtime](terminal-runtime.md) |
| Agent launch presets, Hand Off | [Agent profiles and handoff](agent-profiles-and-handoff.md) |
| Workflow run rows in the panel, Run Workflow | [Workflow](workflow.md) |
| `codans agent status` and `codans agent wait` | [CLI](cli.md) |
| Pane title of the pane card header and the tab chip | [Main window](main-window.md) |

This domain is independent of notifications. Both read the same raw terminal signals, but they answer different questions ("what happened" and "what is happening now"), and neither reads the output of the other. Mute and notification settings do not change the Agents View. The one link is in one direction: notifications ask `AgentStateStore.hasObservedAttention(paneID)` (see [Attention stops](#attention-stops)).

## Two layers: identity and state

Identity and runtime state change at different speeds, so they live in different places:

| Layer | Owner | Changes | Stored |
|---|---|---|---|
| Identity: which `AgentKind` runs in the Pane | `AgentBinder` | When the foreground process group changes | `Pane.agentKind` in `catalog.json` |
| Runtime state: `idle`, `working`, `blocked`, `done`, `error` | `AgentStateStore` | Many times per turn | Memory; a snapshot in `sessions.json` at quit |

`Pane.agentKind` is optional and written only when set, so older catalogs decode. `Pane.agentSessionID` exists in the model, but nothing sets it.

The supported agents are the cases of `AgentKind`. Each kind has an adapter in `AgentRuntimeAdapters` that gives its display name, process names, and OSC 7501 app name. A Pane whose program matches no adapter is not an agent Pane and has no row. A new kind needs an adapter.

## Identification

Identification uses only the Pane's foreground process group. `AgentKindPatterns.classify(foregroundJob:)` ignores the terminal title, the initial command, and notification text, because a title or a command line can say "claude" when no agent runs. An executable named as the agent wins over a runtime wrapper (`node`, `python`, `bun`, a shell) whose command line only mentions the agent.

`AgentBinder` applies the result:

- A match binds the Pane, or rebinds it to a different kind.
- A miss does not release the binding at once. The binding is released only after several consecutive misses, because an agent often gives the foreground to `git`, a build, or a pager for a short time.
- The same kind in a new process group is a new agent: the store drops the old entry and starts a clean one, so the new agent does not inherit the state or title of the old one.
- Pane exit, crash, or close by its Tab clears the binding.

Rebinding follows the foreground process group, not the prompt marks of OSC 133. When Claude exits and the user starts Codex in the same shell, the next sample rebinds the Pane.

## Runtime state and its two sources

The vocabulary of the runtime state is the vocabulary of OSC 7501, unchanged from the report to the UI. The agent's own report decides the state when it applies. The screen decides it otherwise.

```
 OSC 7501 summary of the Pane
        │
        ├── root record app == adapter's app ──► state from the report
        │       (the report "governs")             source: programStatus
        │
        └── no record, or another app ──► viewport text of the active region
                                              │ per-kind classifier
                                              ▼
                                   working | blocked | idle  (+ seen bit)
                                   idle after activity, unseen ──► done
                                              source: screen (cached when detached)
```

### The program status path

The terminal keeps the OSC 7501 records of each Pane in `TerminalEngine`, keyed by `PaneID`. They survive a surface reclaim and go away when the Pane closes. Rules:

- A report governs only when the root record, with `app` inherited down the record tree, equals the `programStatusApp` of the bound kind. A report from another program in the same terminal (for example `brew`) has no effect. A kind gets a `programStatusApp` only after its producer is verified; the others always use the screen.
- The Pane follows the root record. A `blocked` child record blocks the Pane. A `working` child record does not keep the Pane `working`, so background work does not pin it.
- `done` shows until the user looks at the Pane, then shows `idle`. An `idle` report (interrupt, start, `/clear`) never shows as `done`. `error` stays until the next report.
- `working` needs no prior keystroke and has no hold.
- While a report governs: a keystroke or focus does not clear `blocked`, because the agent reports the end of its prompt; the engine does not read the screen of the Pane; and the agent's OSC 9;4 progress is treated as removed, so it does not mark the Pane busy.
- When a report stops governing (`clear`, or the records are dropped), the Pane returns to the screen path. The stale viewport text is discarded, and the end of the report does not read as a finished turn.
- The protocol drops `working` and `blocked` when the reporting process exits. The terminal does not see that exit, so the engine drops `working`, `blocked`, and `idle` records when the Pane is unbound and its foreground is no agent. `done` and `error` stay until a new report replaces them.

### The screen path

`PaneAttentionInterpreter.classifyAgentActivity` reads the active region of the viewport with rules per kind (a spinner, an "esc to interrupt" line, an approval prompt) and returns only `working`, `blocked`, or `idle`. Rules:

- `working` needs user input first: a keystroke in the Pane, or a screen that already shows `working` or `blocked` when the binding forms. Before that, a busy screen counts as `idle`.
- `working` has a short hold, so a frame between two spinner frames does not show `idle`. `blocked` has no hold, so a prompt is never hidden.
- `done` is not a classifier result. It is the display form of a Pane that went from active to `idle` while the user did not look at it. A keystroke or focus marks the Pane seen and turns `done` into `idle`.
- A keystroke or focus also clears `blocked` at once, until the next screen read shows the prompt again.
- The screen path never produces `error`.
- Titles, bells, desktop notifications (OSC 9), and raw output do not feed the state. A bell rings as often for a finished command as for a prompt, and raw TUI repaints would pin the Pane on `working`.

### Attention stops

An attention stop is the moment the agent stops for the user: a new `blocked`, or the end of a turn. The store records whether the user saw each stop. This is separate from the seen bit of the badge: a stop counts as observed only when the Pane is really in view (app active, Pane has keyboard focus) or the user types in it. A catalog focus change from `codans pane focus` while another app is in front does not count. Each new stop starts unobserved, and `working` ends it. Notifications use this to drop the agent's own delayed reminder for a stop that the user already saw.

## Sleeping panes and restart

A Pane whose daemon runs but which has no surface (restored and not opened yet, or reclaimed while idle) is asleep. Nothing reads its screen, so a screen-derived state is the last known one and has `source: cached`. A passive watcher still reads the daemon output, so OSC 7501 reports and titles stay live and keep `source: programStatus`. When the daemon of a sleeping Pane exits, its row goes away. When the surface comes back, the source returns to `screen`.

At quit, the store writes each row's kind, state, and two title sources into the session snapshot. At launch, a record seeds a row only when the Pane's daemon is alive and the kind and state still decode. A seeded row keeps its state until the first live screen read, and its titles until the agent reports again. The snapshot gives a start value; it does not replace identification.

On each structural catalog change, the store and the binder drop entries whose Pane is no longer in the catalog. Without this, a row for a removed Pane shows an em-dash source, goes into the quit snapshot, and is seeded again at the next launch.

## Agent title

The first line of a row is the agent title, defined in [ADR 0009](../adrs/0009-agent-title-and-pane-title-follow-separate-standards.md): the OSC 7501 `title` of the root record, else the OSC 0/2 title that the agent set after the binding, else the agent display name. The OSC 7501 `message` is never in the row; only `codans agent status` prints it. Rules:

- A blank title, or one that says only the agent name (`✳ Claude Code`), counts as no title.
- Only titles set after the binding count. A title the shell or an earlier program set is not the agent's. A title that the agent sets before it is identified is lost until it sets the next one.
- Titles and messages are untrusted program text. They are sanitized with `UntrustedDisplayText` before they are stored, and they are not logged.
- The title is for display only. It does not change the state, the transition time, the row order, or the row height. Fast title changes are coalesced, so a spinner glyph in a title does not redraw the row on each frame.

## The Agents View panel

The panel is at the bottom of the sidebar. A button in the sidebar footer opens and closes it, and the open state persists. The panel and its button exist only when the catalog has at least one Project; a tag filter that hides all Projects does not hide the panel. With the Auto-open setting on, the panel opens when any agent goes `working` or `blocked`. It never closes by itself.

- **Header.** "Agents View", a `(N)` count when more than four agents run, and a button that switches between Normal (two lines: agent title, then Worktree and Project) and Compact (the Worktree and Project line only). The button and the Settings picker write the same setting.
- **Row.** Agent logo, text lines, and a state icon. A `cached` state shows a static icon with a "Last known state" tooltip, so a restored `working` does not look live.
- **Order.** With Auto-sort on: `blocked`, `error`, `done`, `working`, `idle`, then the newest transition first. Reorders are debounced so the list does not jump on each state change. With Auto-sort off, rows keep the order in which they appeared.
- **Actions.** A click focuses the Pane and selects its Project, Worktree, and Tab; the panel stays open, so the user can jump from agent to agent. `⌥1` to `⌥9` (configurable) select the Nth row while the panel is open. The context menu has Hand Off… and Run Workflow.
- **Workflow runs.** Active workflow runs show as a group under the agent rows.

A row has no hover card. A popover that resizes while it shows crashed the app on a row click; see [the row-click segfault](../lessons-learned/2026-08-20-agents-view-row-click-segfault-in-popover.md).

## Other readers of the state

- `codans agent status` lists the rows with state, source, blocked kind, and message, and marks a sleeping row `(sleeping)` and a row without a daemon `(not live)`. `codans agent wait` waits on the server for a state, `changed`, or `exit`. See [CLI](cli.md).
- The command queue and workflows treat `idle`, `done`, and `error` as the end of a turn, so an agent that fails does not stop a workflow forever.
- The quit dialog counts a Pane with a `working` or `blocked` agent as busy.

## Traps

- **A state that sticks.** On the program status path, check that the root record's `app` matches the adapter; a report from another program never governs. On the screen path, an agent that changed its TUI no longer matches its classifier rules; each kind has viewport fixtures in the interpreter tests.
- **`done` from the inbox.** Do not derive `done` from notification read state. The store owns its own seen bit, so mute and dedupe rules do not leak into the agent state.
- **A reattach gap.** When a sleeping Pane gets its surface again, the watcher stops before the surface attaches. A report in that short gap is lost, and the next report corrects the state. A watcher signal that arrives after the surface exists is dropped, so a stale signal never overwrites a live one.

## Implementation shape

`CodansCore/Agents/` holds the value types: `AgentKind`, the adapters, the foreground job classifier, and the OSC 7501 records. The screen classifier is in `CodansCore/Notifications/`. In the app, `TerminalEngine` (`Runtime/`) samples foreground jobs, reads viewports, and keeps program status records, then emits `TerminalEvent`s. `AgentBinder` (`Runtime/`) turns foreground jobs into `Pane.agentKind` through `HierarchyClient`. `AgentStateStore` (`App/Features/AgentState/`, `@Observable`) derives the state, and the panel views read it. Data flows one way: engine, then binder and store, then the views and the IPC handlers.
