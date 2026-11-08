# 0009. Agent title and pane title follow separate standards

Status: Accepted.

## Context

Three places show a title for a pane, and each one resolves it in its own way:

- The pane card header (`PaneCardHeader.title`): the live OSC 0/2 title, then
  the live working directory, then the persisted working directory, then
  "Terminal".
- The tab chip (`TabBarRowView.resolvedTitle`): the tab name, then the live
  tab title, OSC 0/2 title, or working directory base name of the selected
  pane, then a cached title, then "Tab N".
- The first line of an Agents View row (`AgentStateStore.activityText`): the
  OSC 7501 `message`, then the OSC 0/2 title that the agent set after it
  started, then the agent display name.

The owner compared this with two reference projects. Both use one rule for a
pane or tab title (the live OSC title, then a stored title) and show no
agent status text in that title.

The OSC 7501 `message` changes many times during one turn. As the first line
of a row it is too detailed. OSC 7501 also has a `title` field, a short label
of what the program works on (192 bytes or less). Codans parses and stores it
(`ProgramStatusRecords.Record.title`) but does not show it.

## Decision

1. **Two titles, two standards.** An Agents View row shows agent information,
   so its title comes from the agent's OSC 7501 report. A pane card header
   shows terminal information, so its title comes from OSC 0/2. The two can
   show different text for the same pane. That is expected.
2. **Agent title.** The first line of an Agents View row is the OSC 7501
   `title` of the agent's root record, else the OSC 0/2 title that the agent
   set after it started, else the agent display name (for example "Claude
   Code"). The OSC 7501 `message` is not shown in the row.
3. **Redundant text.** A title that is blank, or that says only the agent's
   name (`✳ Claude Code`), counts as no title in the Agents View row. The pane
   header shows the OSC 0/2 title as it is.
4. **An empty title does not erase a title.** When a pane's live OSC 0/2 title
   becomes empty after it had a title, the header keeps the last title.
   Shells clear the title while a command runs and set it again at the
   prompt. The header falls back to the working directory only when the pane
   has had no title.
5. **Untrusted text.** The pane header and the tab chip sanitize an OSC 0/2
   title with `UntrustedDisplayText` before they show it, the same as the
   Agents View.
6. **Shell at its prompt.** When the pane's foreground process group holds
   only the shell (`ForegroundJobClassifier`), the pane title is the working
   directory with the home directory shown as `~`, and the OSC 0/2 title is
   not used. When any other process holds the foreground, the pane title is
   the OSC 0/2 title.
7. **The tab chip shows the pane title.** The chip shows the tab name when
   the user set one, else the pane title of the tab's selected pane, the same
   text as that pane's header. The chip does not read the Ghostty tab title
   and does not shorten the working directory to its last component. The
   tab's cached title is used only while the selected pane has no surface,
   and it caches the pane title.
8. **The pane title survives a restart.** The zmx daemon keeps the last OSC
   0/2 title of its session and replays it on attach. The daemon sees all
   output while the app is closed, so the replayed title is current. The
   daemon does not replay the working directory (OSC 7): until the shell
   reports it again, the pane title at the prompt uses the working directory
   that the app persisted for the pane.
9. **The agent title survives a restart.** The state snapshot that
   `AgentStateStore` saves at quit includes the OSC 7501 `title` and the
   agent's OSC 0/2 title. A restored row shows them dimmed, with the same
   rule as a cached state, until the agent reports again.
10. **Out of scope.** A user name for a pane, and throttling of header title
    updates.

## Reasons

- Each title follows one standard, so a future change has a clear source to
  follow: OSC 7501 for agent information, OSC 0/2 for terminal information.
- The OSC 7501 `title` changes at the speed of a task, not of each step, which
  suits one line in a list.
- The OSC 0/2 fallback keeps a useful line for agents that do not report OSC
  7501, or that report it without a `title`.
- At the prompt, shell frameworks set titles in many formats (oh-my-zsh sets
  `user@host:~/path`). The working directory gives the same title for every
  shell setup, and the app persists it for each pane, so it is known after a
  restart.
  Ghostty's own shell integration gives the same result: the directory at the
  prompt, the command while it runs.
- When the chip and the header resolve the title in different ways, they show
  different text for the same pane, for example a cached "Claude Code" on the
  chip and a directory on the header after a restart.
- Before this decision, the zmx daemon dropped the title (its terminal ignores
  `window_title`), so every pane lost its title on restart until the program
  set it again. A title kept by the
  daemon is current; a title cached by the app can be stale.

## Trade-offs

- The header and the Agents View row of one pane can show different text.
- An agent that sends OSC 7501 without a `title` shows its OSC 0/2 title,
  so the source of the row text can change between agents.
- Keeping the last title can show a stale title if a program exits and the
  shell does not set a new title.
- A title that the user's shell sets at the prompt is not shown.
- The prompt check depends on the foreground job poll, so the title changes
  one poll after a command starts or ends.
- The chip can show a long path or title where it showed a short directory
  name before.
- The title replay is a change to the zmx fork that must be kept across
  upstream updates.

## Reconsider when

- The OSC 7501 specification changes the meaning of `title` or `msg`.
- Verified OSC 7501 producers send no `title`, so the row always shows the
  OSC 0/2 fallback.
