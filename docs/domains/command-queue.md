# Command Queue

The Command Queue holds prompts or shell commands that wait to go into one Pane. The user writes a line now and codans types it later: when the agent in the Pane finishes its turn, or at a set time, once or again and again. This lets a user line up the next prompt for an agent without watching the Pane, or nudge an agent on a timer.

Availability: Available. There is no CLI verb and no command palette item for the queue.

## Scope and ownership

| Topic | Owner |
|---|---|
| Agent runtime state (`idle`, `working`, `blocked`, ...) | [Agent State](agent-state.md) |
| Skill completion in the composer | [Agent Skill Completion](agent-skill-completion.md) |
| Surface reclaim and the reclaim veto | [Terminal Runtime](terminal-runtime.md) |
| Workflows, which also send lines to Panes | [Workflow](workflow.md) |
| Pane header, actions menu, and the main window sheets | [Main Window](main-window.md) |

## Entries and where they live

An entry (`QueuedCommand`) has an ID, the text exactly as the user typed it, a timing, and a creation time. The queue is the array `Pane.commandQueue` on the Pane row in the catalog, so it is saved in `catalog.json` and survives a relaunch. The Pane row, not its process, is the identity that a deferred command belongs to: a relaunch restores the Pane, so it also restores what the Pane still owes.

There are two timings:

- **After the current task** (`afterCurrentTask`): waits until the Pane is ready (see below), then fires once.
- **Scheduled** (`scheduled(at:, repeatEvery:)`): fires at a wall-clock time. With a repeat interval, the entry stays in the queue and moves to its next occurrence after each fire.

"Send now" is not a timing. It writes to the Pane at once and never becomes an entry, so every entry in a queue is work not yet delivered.

Rules:

- `HierarchyManager.setCommandQueue` is the single writer of a queue. The composer, the overlay, and the runner all write through it, and each change is saved with the rest of the catalog.
- Appends read the live queue, not a snapshot, because the runner can remove an entry while the composer is open.
- The queue decodes leniently. An entry with an unknown timing kind (written by a newer build) drops the queue of that Pane, not the whole catalog. The timing is a `kind`-tagged JSON object for this reason.
- The queue is written to the file only when it is not empty.

## When an entry fires

`CommandQueueRunner` starts at app launch and runs one drain pass about twice a second. Each pass walks the Panes that hold a queue, in Worktrees that are not archived, and fires at most one entry per Pane:

```
for each Pane with a queue:
  no live surface          -> skip (hold the whole queue)
  fired < 3 s ago          -> skip (settle window)
  a scheduled entry is due -> fire the earliest due one, ready or not
  else Pane is ready       -> fire the first afterCurrentTask entry
  else                     -> wait
```

- **Ready** comes from the agent state when the Pane has an agent: `idle`, `done`, and `error` count as the end of a turn. `working` and `blocked` do not. `blocked` means the agent waits for an answer to a specific question, and a queued prompt typed there would become that answer. A Pane with no agent is ready when no foreground command runs in it. Terminal-busy signals are not used for agent Panes, because agents emit progress sequences during the whole task.
- **Scheduled beats ready.** A due scheduled entry fires even while the agent is working. The user asked for a time, so a busy Pane does not postpone it.
- **One at a time.** Only the head of the after-task entries can fire, and the settle window keeps 3 seconds between two fires in one Pane. Readiness comes from the rendered terminal state, which lags the keystroke: without the window, an agent that just got a prompt still reads as idle, and the whole queue would go into one prompt.
- **Missed repeats fire once.** After a fire, a repeating entry moves to the first occurrence strictly after now. A repeat that came due many times while the app was closed fires once on relaunch, not once per missed period. A one-shot scheduled entry that is past due fires on the first pass that can deliver it.
- The runner is polled, not event-driven, because two of the conditions are wall-clock times. One pass gives one order of decisions.
- The settle log is in memory only; the queue itself and the next occurrence of a repeat are in the catalog.

### No surface, no fire

The runner fires only into a live surface. Without one, the text would go nowhere and the entry would still be consumed. So:

- A Pane whose Tab was not opened in this session holds its whole queue until its surface exists. A scheduled entry that came due in the meantime fires once, on the first pass after that.
- A Pane with a non-empty queue vetoes surface reclaim, so a queued Pane in the background keeps its surface and its queue keeps running. See [Terminal Runtime](terminal-runtime.md).
- Queues in archived Worktrees do not run. They stay in the catalog.

## How text reaches the Pane

All delivery goes through `TerminalClient.sendCommand`: the text goes in as one paste, then Return follows as a separate keypress after a short gap. A multi-line prompt arrives in an agent's composer with its line breaks, and the Return submits it instead of being read as part of the paste. Do not send queued text through `sendInput`, which presses Return after each line. The stored text has no trailing newline; the sender adds the submit.

## The composer

⌘L (configurable, `toggleCommandQueue`) opens the composer sheet on the focused Pane of the current Tab. "Command Queue…" in the Tab menu and in the Pane actions menu opens it for that Pane. With no Pane, the shortcut does nothing. The same shortcut on the same Pane closes the sheet.

- The sheet has a draft editor and a send timing menu: "After task" (the default), "Send now", and "Schedule". Schedule opens a popover with the date and time and an optional repeat (an amount and a unit: seconds, minutes, hours). The first scheduled time defaults to 10 minutes from now, rounded down to the minute.
- Return or ⌘Return submits; Shift-Return adds a line break. The draft is trimmed at its ends only. An empty draft does not submit. A submit closes the sheet.
- The draft is kept per Pane in memory while the sheet is closed, and comes back when the sheet opens on that Pane again. It is cleared on submit and when the Pane closes. It is not saved across a relaunch.
- The file button picks one or more files. Their absolute paths, each in POSIX single quotes, go into the draft at the caret, separated by spaces. Picking files does not send. The New Agent composer uses the same rule.
- The Skills button and the call prefix offer the skills of the agent that runs in the Pane now. A Remote Project gets no skill completion. See [Agent Skill Completion](agent-skill-completion.md).
- The composer shares the main window's sheet slot: opening the New Agent sheet closes it.

## Queued entries in the Pane

While a Pane has a queue, its header shows a badge with the count. A click on the badge opens a list of the entries over the top of the terminal; it never opens by itself. Each row shows a one-line summary of the text (line breaks as `⏎`), the timing ("After current task", "At 14:30 · every 30 min"), and the full text as a tooltip. A row's remove button deletes that entry; Clear All empties the queue. A click outside the list, or the last entry leaving, closes it. Whether the list is open is view state of that Pane and is not saved.

## Closing a Pane with a queue

The queue goes away with its Pane. Before a user closes a Pane or Tabs whose Panes hold queued commands, a sheet asks for confirmation, with Cancel as the default button. The Remove Worktree and Remove Project confirmations add the count of commands that will be discarded. The CLI and run-script auto-close do not ask. The prompt is skipped when none of the Panes has a live surface.

## Traps

- "Send now" on a Pane without a live surface does nothing, with no error.
- A Pane with a queue never gives up its surface, so a long repeating schedule keeps that Pane's memory in use.
- A schedule set to fire in seconds is still limited by the settle window: two fires in one Pane are at least 3 seconds apart.
- An after-task entry on an agent Pane that stays `blocked` waits until the user answers the agent.

## Shape of the implementation

```
CommandQueueView/Feature (sheet, draft)  ─┐
Pane header badge + overlay list          ├─► HierarchyManager.setCommandQueue ─► Pane.commandQueue (catalog.json)
CommandQueueRunner (drain pass) ──────────┘            ▲ reads queues
        │ readiness: AgentStateStore, else terminal busy
        └─► TerminalClient.sendCommand ─► live surface
```

The queue policy (which entry fires, how a repeat moves on) is pure code next to the model in `CodansCore`. The runner adds the clock, the settle window, and the surface check. The composer only edits a draft and appends entries.
