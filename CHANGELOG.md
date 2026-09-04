# Changelog

All notable changes to codans are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project does not yet follow semantic versioning — every release until
1.0 is a developer build. Releases are dated.

## [Unreleased]

### Added

- **omp agent support.** The Agents View now recognises [omp](https://omp.sh/)
  (oh-my-pi) panes: foreground-process detection, working / blocked / idle
  activity badges tuned to its loader and approval-selector rendering, the
  omp glyph, and resumable session history — local and on remote hosts —
  via `omp --resume`.
- **Agent profiles — named launch presets for coding agents.** Settings →
  Agents holds one profile per agent (model, reasoning effort, execution
  mode, placement, extra arguments, launch-scoped environment variables, an
  optional dedicated home, a custom icon), with a live preview of the exact
  command codans types. Start one from the worktree toolbar's Agents button,
  the Command Palette ("Launch Agent: …"), or the CLI (`codans agent list` /
  `codans agent launch`).
- **Hand off a task between agents.** `codans handoff to <agent> --brief -`
  archives the previous round under the worktree's `.codans/handoff/`,
  installs the source agent's own briefing, regenerates repository and
  session context, and starts the receiver in a background tab with a
  kickoff prompt; `codans handoff save` checkpoints without a receiver. In
  the app, "Hand Off…" (a pane's info menu, Command Palette, Agents View row) asks
  the live agent to run that same command with its briefing and jumps to the
  receiver when it finishes, with a context-only fallback while waiting.
- The worktree toolbar's Agents menu now lists only agents whose CLI the
  shell can resolve. The check fails open: nothing is hidden before the
  scan answers, and if it would hide every profile they all come back.
- **Per-pane info menu.** Every terminal pane carries a collapsed info
  button in its top-right corner. Opening it shows the worktree the pane
  runs in — path, branch, uncommitted `+N −M` — and the agent bound to it,
  and offers "Hand Off…" for that pane. Clicking anywhere else, or Escape,
  collapses it.

### Changed

### Deprecated

### Removed

### Fixed

- The CLI now honours `$CODANS_SOCKET_PATH` when no `--socket` flag is
  given, so a command run inside a pane reaches the app that spawned it
  rather than the installed release build.

- Worktrees no longer disappear when the disk fills up. A `git worktree list`
  that dies under disk pressure reached codans as an empty — but perfectly
  valid-looking — result, and every non-pinned worktree in the project was
  soft-archived and its panes torn down, agents included. An empty discovery
  is now treated as a failed one, and auto-archiving leaves a log entry.
- A failed catalog save no longer endangers the catalog. When the disk was
  full, codans moved the last good `catalog.json` aside, so the next launch
  could come up with no projects at all.

### Security

## [0.5.0] - 2026-08-25

### Added

- **Server projects — work on a remote machine as if it were local.** Add a
  project by host, user, port, and path, and codans manages that remote
  directory exactly like a local one: worktree discovery, create and remove,
  terminals that reconnect after a dropped connection or an app relaunch,
  git status chips in the sidebar, agent detection in the Agents View,
  session history, and Open in Editor through Zed and the VS Code family's
  SSH remoting. Authentication is your existing `~/.ssh/config` and
  ssh-agent — codans never stores a credential.
- **A summary card when you hover an Agents View row.** The card leads with
  the task the agent was given, followed by what it is doing right now, so
  you can tell sessions apart without focusing each pane.
- **A sidebar banner when git cannot run at all.** If the Xcode license has
  never been accepted or the Command Line Tools are missing, every project
  used to come up empty with no explanation. codans now says what is wrong,
  shows the exact command that fixes it, and offers a Recheck button.
- **Product marker in every pane's environment.** Panes now export
  `TERM_PROGRAM=codans` and `TERM_PROGRAM_VERSION=<app version>`, so shell
  scripts and coding agents can cheaply detect they are running inside
  codans (same convention as Terminal.app, iTerm2, and ghostty). A
  `TERM_PROGRAM` inherited from the terminal that launched codans no longer
  leaks into panes.
- **Short handles for tabs and panes in the CLI.** `codans tree` now prints
  `Tab t3:` / `Pane p7:`, and every command that takes a tab or pane accepts
  those handles. They stay stable for the life of the app and are never
  reused, so a handle from a closed tab fails outright instead of hitting
  the wrong one.

### Changed

- **CLI connection errors say what to do about them.** Instead of one
  "cannot connect" bucket, the CLI distinguishes "the app is not running"
  from "the socket belongs to another user", prints a `hint:` line with the
  fix, returns a distinct exit code per category, and reports the same
  status through `codans doctor`. `codans launch` now fails fast on
  problems that starting the app cannot clear.
- **CLI commands find their own pane more reliably.** A command run inside a
  pane resolves `current` / `.` to that pane even when the environment was
  scrubbed — agent-spawned subshells and wrapper scripts no longer lose
  their context.

### Fixed

- Clicking a row in the Agents View could close the app outright. It no
  longer can.
- Closing one half of a split — including stopping a run pane — no longer
  leaves the surviving pane blank until you switch away and back, and that
  pane now takes keyboard focus immediately instead of waiting for a click.
- The Add Project "+" in the sidebar toolbar could render white-on-white
  after switching to light appearance, so it read as missing.
- A settings file you symlinked into a dotfiles repository stays a symlink;
  saving settings no longer replaces the link with a plain file.

## [0.4.21] - 2026-07-24

### Changed

- **Faster, better-looking app launch.** Startup is quicker — a redundant
  daemon check and a non-critical file sweep no longer block the first frame,
  so a stalled session no longer drags launch out. While the app loads, it now
  shows a skeleton of its real two-column layout instead of a bare loading
  screen.

## [0.4.20] - 2026-07-24

### Added

- **Agent session summary card on hover.** Hovering an Agents View row for a
  moment now pops up a card with the agent's identity, its project and worktree,
  a live elapsed-time tick, session id, and a tail of the pane's output — so you
  can size up a session without switching to its pane.
- **`codans pane capture --wait-stable`.** Pane capture can now wait for a pane's
  output to settle before reading — fire a command, wait for it to actually
  finish, then read the stabilized text (tuned with `--stable-ms` /
  `--interval-ms` / `--timeout-ms`).
- GoLand joins the editors codans can open a worktree in, alongside the rest of
  the JetBrains family.

### Changed

- **Every agent's status now debounces "working → done."** The brief hold that
  kept a Claude Code pane from flickering between working and finished on a
  single dropped spinner frame now applies to all coding agents (Codex, Gemini,
  cursor-agent, opencode, and the rest). Any agent whose activity cue skips a
  frame between repaints stays "working" through the gap instead of blinking to
  "done" and back.

## [0.4.19] - 2026-07-22

### Added

- **Resume past agent sessions from the tab bar.** A new history button — the
  clock next to `+` — lists every Claude Code and Codex session recorded for the
  current worktree, grouped by agent and newest first. Hit a session's play
  button to reopen it in a fresh tab with the agent's own resume command.

### Changed

- The Archived Worktrees sheet now shows when each worktree was archived, with a
  tidied-up layout — aligned rows, a bottom Close bar, and an icon button for
  Unarchive.

## [0.4.18] - 2026-07-21

### Fixed

- Creating a worktree no longer occasionally fails at the last moment with an
  error — and a duplicate sidebar row — even though the worktree was actually
  created; a timing race with the background refresh is resolved.
- Keyboard shortcuts in the worktree header's command dropdown are now
  right-aligned in the trailing column like standard macOS menus, instead of
  running inline after the command name.

## [0.4.17] - 2026-07-21

### Added

- **Run scripts now have a dedicated, persistent pane.** Re-running a script
  reuses its own pane — even across an app relaunch — instead of spawning a new
  one each time. A running script shows as a tinted tab icon plus a pulsing dot
  on its worktree in the sidebar; hover the dot for a Stop button.

### Fixed

- Stopping a run script — from the toolbar, the sidebar's Stop button, or by
  archiving or removing its worktree — now fully terminates the underlying
  process instead of leaving it running in the background.

## [0.4.16] - 2026-07-18

### Changed

- **Worktree creation, archiving, and removal are now narrated, interruptible
  lifecycles.** The sidebar row streams each phase live (setup output, phase
  glyphs, a shimmer), focus follows a new worktree while you stay free to click
  away, and archive/delete finish on their own instead of waiting for a stray
  keypress. A branch-name conflict now explains exactly why the name is taken
  instead of opening an in-app resolution flow.

### Fixed

- **⌘W now closes the active pane, then the tab, then the window** (matching
  iTerm and Terminal.app), instead of tearing down the whole window — which
  could leave the app running with no window, looking as if it had quit.
- Archiving a worktree now stops its coding-agent daemons and clears their rows
  from Active Agents, instead of leaving those processes running in the
  background for days.
- Worktrees that git has marked "locked" can now be removed, and a genuine lock
  shows a readable message instead of a raw error code.

## [0.4.15] - 2026-06-25

### Added

- **Project commands in the `codans` CLI.** A new `codans project commands`
  group lists, adds, edits, and removes a project's saved commands straight
  from the terminal.

### Fixed

- **Runaway memory growth.** A leak in the terminal's text-reading path could
  push the app's memory into the gigabytes over a long session with many
  panes — now fixed.
- Coding-agent panes again recognize Claude Code when it runs through its
  `claude.exe` launcher, so the agent reappears in the agents view.
- The tab spinner no longer flickers back on each time a coding agent runs a
  tool.

## [0.4.14] - 2026-06-25

### Added

- **More commands in the Command Palette.** Open Project, Clone Repository,
  and a curated set of worktree, project, tab, and pane actions are now all
  reachable from the palette. Typing a level name — worktree, tab, pane, or
  project — surfaces that whole group of commands.

### Changed

- The Command Palette drops two rows that did nothing ("New Window" and
  "Show Tab Overview").

### Fixed

- Archived worktrees now age out past their retention period even while a
  window stays frontmost, and changes to update-check preferences take effect
  immediately instead of only after the next launch.
- A tab no longer shows a duplicate spinner — and a clipped title — while a
  coding agent animates its own progress indicator in the live tab title.

## [0.4.13] - 2026-06-22

### Added

- **Frosted-glass terminal background.** Settings → Terminal gains a Background
  section — pick a background opacity (down to 50%) and a glass blur style
  (Regular or Clear) to render a translucent, blurred terminal over whatever is
  behind the window.
- **An update reminder in the sidebar.** A blue update button now appears in the
  sidebar toolbar whenever a newer build is available — and stays put even after
  you choose "Skip This Version" in the updater. Click it to check now and
  reopen the update flow.
- **Archive or remove every merged worktree at once.** The Project ⋯ menu adds
  "Archive All Merged" and "Remove All Merged", applying the usual archive or
  delete to every worktree whose pull request has been merged — shown with a
  count and gated behind a confirmation step.

### Changed

- **The menu bar is reorganized.** The Command Palette (formerly "Quick
  Action…") moves to the Codans app menu; the Commands menu and Toggle Git
  Viewer fold into the Worktree menu; New Tab and Close Tab move into the Tab
  menu; and the File menu's items are now labeled "Open Project" and "Clone
  Repository". All keyboard shortcuts are unchanged.

### Fixed

- **Panes no longer get stranded after sleep, logout, or a display change.**
  Following one of these, a pane's terminal could quietly lose access to your
  login keychain — coding agents would suddenly prompt you to sign in again, and
  ssh / gh would stop working. Panes now keep their session identity across
  reconnects, so a stranded terminal is recycled cleanly instead.
- **Dragging a tab no longer risks a crash.** A rare crash while dragging a tab
  over the reorder highlight is fixed.

## [0.4.12] - 2026-06-22

### Added

- **Terminal cursor and font settings.** Settings → Terminal now lets you pick
  the cursor shape, font family, and font size alongside the theme. Changes
  write to your ghostty config and take effect in running terminals without a
  restart.
- **Clone a repo straight from Add Project.** The sidebar's "+" now offers both
  "Open Project" (pick any local folder) and "Clone Repository" — paste a Git
  URL, choose a destination, and Codans clones it and adds it as a project in
  one step.

### Changed

- **The project Environment Variables editor is cleaner.** The add/edit sheet is
  rebuilt as a compact native card, editable rows gain a copy-name button, and
  built-in variables now show their resolved value (e.g. CODANS_ROOT_PATH shows
  the project root).
- **Built-in pane variables are renamed from `TOUCHCODE_` to `CODANS_`.**
  `TOUCHCODE_WORKTREE_PATH` and `TOUCHCODE_ROOT_PATH` are now
  `CODANS_WORKTREE_PATH` and `CODANS_ROOT_PATH` — update any pane scripts that
  reference the old names.

### Fixed

- **Panes that run a command and exit now close themselves.** A "Close when
  finished" command — or simply typing `exit` — no longer leaves the tab parked
  on a blank screen with a cursor until you press Return; the pane tears down and
  its close policy fires as intended.
- **The worktree command dropdown no longer has a wide empty gutter.** The Run /
  command menu now hugs its widest label instead of stretching past its content.

## [0.4.11] - 2026-06-21

### Fixed

- **Dragging a tab to reorder no longer glitches into the titlebar.** The
  lifted copy that follows your cursor during a reorder now stays pinned to
  the tab row instead of floating up into the window titlebar or painting a
  tall white column above the tabs — it tracks the cursor as a single,
  cleanly-clipped tab chip.
- **Stale agent rows clear from the Agents view.** Agent entries left behind
  after their pane is gone — the ones that showed up as blank "— —"
  placeholders — now disappear on their own instead of lingering across
  launches.
- **Loading screens keep the spinner and its caption together.** On launch
  and while a worktree is still loading, the spinner and its text no longer
  drift apart at larger window sizes; they stay centred as one unit.

## [0.4.10] - 2026-06-19

### Fixed

- **Finished agents no longer flip back to "working."** When a coding agent
  like Claude Code wraps up, its end-of-run summary line no longer tricks the
  Agents view into relighting the "working" badge — a done agent stays done.
- **Phantom agents clear from the Agents view.** When an agent exits and leaves
  a plain shell (or an open editor like vim) behind, the Agents view no longer
  keeps showing a ghost entry for the agent that's already gone.
- **Fixed an occasional crash when switching tabs or worktrees.** Tapping a tab
  chip to move between tabs or worktrees no longer sometimes brings the app down.

## [0.4.9] - 2026-06-18

### Changed

- **Project names now wear their project color.** The color set in Settings →
  General → Color tints the project name in the sidebar, the Agents view, and
  the worktree header — not just the project dot. Projects with No Color keep
  the default styling.

### Fixed

- **Agent status no longer gets stuck on "working."** After a coding agent
  (like Claude Code) finishes, the Agents view badge reliably settles to
  "finished" instead of staying lit as "working."
- **Recreating a worktree you deleted earlier works again.** Making a new
  worktree with the same name as one you'd removed no longer fails with "Branch
  already exists" — it reuses the leftover branch and keeps its commits. When a
  branch can't be removed because another worktree still has it checked out, you
  now get a notice instead of a silent skip.
- **Opening Settings → Project → General no longer drops your cursor into the
  Delete Script box.** The caret stays put; the command-editor popover still
  focuses its field as before.

## [0.4.8] - 2026-06-18

### Added

- **Global commands.** Define project-agnostic commands in Settings → Global
  Commands and run them from any worktree — they appear in the worktree-header
  Command menu and the Command Palette right alongside your per-project commands.

### Fixed

- **Agents come back with the right status.** An agent that was working or
  blocked when you quit no longer reappears as idle — after relaunch the Agents
  view restores its real state.

## [0.4.7] - 2026-06-17

### Added

- **Migrate your old touch-code state to Codans.** A new
  `scripts/migrate-touch-code-to-codans.py` brings your touch-code config and
  worktrees over to Codans, repairing the git-worktree metadata that a manual
  move would break. Dry-run by default; pass `--apply` to make changes, and
  quit the app first.

### Changed

- **Reordering projects in the sidebar is now a direct drag.** Tapping the sort
  glyph drops the sidebar straight into a reorder session with drag handles — no
  separate menu or sheet — and tapping it again finishes.
- **The About pane links to codans.dev.** The website line in Settings → About
  is now a clickable link.

### Fixed

- **"Snapshot and exit" on quit now actually preserves your panes.** Choosing
  Settings → General → On quit → "Snapshot and exit" used to bring panes back
  empty; it now restores each pane's last screen, scrollback, and working
  directory into a fresh shell on relaunch. (Use "Keep session running" to keep
  the programs themselves running.)
- **Panes no longer get stuck at the wrong size after the display sleeps.**
  Waking the display, or uncovering a window that was behind another, no longer
  leaves a pane rendering at a stale width — the terminal resyncs its size and
  repaints.

## [0.4.6] - 2026-06-11

### Changed

- **Renamed the product from "touch-code" to "Codans."** The app is now `Codans.app` with bundle id `com.gumpw.codans`, the CLI binary and command are `codans` (was `tc`), and the Homebrew cask is `codans`. On-disk state moves to `~/.config/codans`, `~/Library/Caches/codans`, `~/.codans/repos`, and the control socket to `/tmp/codans-<uid>.sock`. No migration is performed — existing `touch-code` state, worktrees, and installed CLI are left in place and must be removed or re-created manually.

## [0.4.5] - 2026-06-10

### Added

- Trae, Trae CN, Qoder, and CodeBuddy join the editors you can open a worktree in.

### Fixed

- After logging out and back in, switching users, or waking from sleep, a pane's
  terminal could quietly lose access to ssh, gh, and the login keychain; these
  panes now recover automatically on relaunch instead of needing a brand-new pane.

## [0.4.4] - 2026-06-09

### Changed

- Reordering tabs by dragging is now animated live: neighboring tabs slide
  aside as you drag, and the tab you're holding lifts with a shadow and
  settles smoothly into its new position.

## [0.4.3] - 2026-06-03

### Added

- **Automatic cleanup of archived worktrees.** Settings → Worktrees → Cleanup can
  now auto-delete archived worktrees after a retention window you choose (1 to 30
  days), and optionally delete a worktree's remote branch when you remove it.

### Changed

- **The Run button now doubles as Stop.** While a command is running in its pane,
  the toolbar Run button turns into a red Stop — click it, or press ⌘., to
  interrupt the command without closing the pane. Re-running a command reuses its
  pane instead of piling up new tabs, and the button shows its shortcut while ⌘
  is held.
- **The sidebar refreshes right after a commit or git command.** The diff count
  and pull-request badges used to lag by up to a minute; now committing, pushing,
  or running a `git` / `gh` command in a pane updates them within a few seconds.
- **The Command Palette has a new look.** System glass material, rounder corners,
  a lighter frosted tone, and a calmer neutral-gray selection.
- **The Command Palette ranks worktrees by project name.** Typing a project name
  now surfaces that project's worktrees at the top instead of burying them behind
  unrelated fuzzy matches.
- **Jumping to a worktree reveals it in the sidebar.** Selecting a worktree from
  the Command Palette, the Active Agents panel, or a notification now expands its
  project and scrolls the row into view.

### Fixed

- **The command editor stays put while you type.** In Settings → Commands, the
  inline editor now focuses when its popover opens, shows the caret immediately,
  no longer jumps the caret to the start mid-word, and no longer reverts a field
  you just changed (like New Tab ⇄ In Place) on the next keystroke.
- **Clicking a Command Palette row runs that row.** Clicking an item no longer
  occasionally fired the previously-used command instead — only Return commits the
  highlighted row, and a click runs exactly what you clicked.
- **First launch shows one consistent tone.** With no project open, the empty
  window no longer splits into mismatched light and dark areas; it stays on a
  single neutral system tone regardless of your terminal theme.

## [0.4.2] - 2026-06-02

### Added

- **Drag panes to rearrange a split.** Every pane in a multi-pane tab now has a
  drag handle — drop it onto another pane's top, bottom, left, or right edge to
  move it there. The pane's shell keeps running across the move; nothing restarts.

### Changed

- **The diff-stat chip updates as you type.** The sidebar's +N −M count used to
  refresh only on commit, branch switch, or reopening a row — it now reflects
  uncommitted edits made in any pane or editor within about a second, and the
  digits roll smoothly to their new values.
- **The built-in Run command is now permanent and bound to ⌘R.** Run ships with
  the conventional ⌘R shortcut by default and can no longer be deleted; its remove
  button is disabled with a tooltip explaining why.
- **Clearing a command's shortcut moved to the right-click menu.** Clear Shortcut
  is now a right-click action on the shortcut cell instead of a button inside the
  recorder popover.

### Removed

- **The built-in Git Viewer has been removed.** The in-app diff and history viewer
  is gone; the ⌘⌥G shortcut and the Settings → Git Viewer picker now open your
  configured external client (GitHub Desktop, Sourcetree, Tower, Fork, …) instead,
  or do nothing if none is selected.

### Fixed

- **Removing a moved or deleted worktree always works now.** Removing a worktree
  whose folder had been relocated or deleted used to fail with a raw "error 6" and
  leave the row stuck forever; removal is now reliable and surfaces a readable
  message if anything genuinely goes wrong.

## [0.4.1] - 2026-06-01

### Fixed

- **A freshly split pane accepts input again.** Splitting a pane could leave the
  new pane showing a blinking cursor while silently dropping every keystroke;
  it now takes focus and is ready to type into immediately.
- **Panes open at their final width.** Opening or revisiting a pane — or switching
  to a worktree that wasn't loaded yet — no longer flashes at the wrong column
  width and reflows a moment later; the shell renders at the right size from the
  first frame.
- **Creating a worktree opens exactly one pane.** Worktree creation could spin up
  a second, broken pane; it now reliably opens a single working pane.

## [0.4.0] - 2026-06-01

### Added

- **Terminal panes survive quitting and relaunching the app.** A new Settings → General "Resume panes on launch" toggle (on by default) keeps your panes — and the programs running inside them — alive across an app restart, so you reopen right where you left off. Turn it off and each pane is instead restored from a snapshot of its last screen. Settings shows how many sessions can be resumed and offers a "forget all" action to clear them.
- **Quitting asks before closing active panes.** Quitting while panes are still doing work now shows a confirmation instead of tearing everything down silently.
- **The Active Agents panel remembers its agents across launches.** Agents that were running before you quit reappear after relaunch instead of starting from an empty list.
- **New `codans pane` commands.** `info --json` dumps a pane's full state, `read` gains additional variants, and `close` shuts a pane down — ending its resumable session — from the shell.

### Changed

- **Settings → Scripts is now Settings → Commands, with inline editing.** The pop-up script editor is replaced by an inline table — two-line rows, a per-command color and kind, and a dedicated sheet for environment variables. Every command can reference built-in worktree-path and project-root variables, and project lifecycle scripts now live under General.

## [0.3.5] - 2026-05-31

### Added

- **Merge conflicts now stand out on every pull-request surface.** A conflicted PR turns its number, border, and warning triangle red — in the sidebar row and the titlebar badge alike — and the hover popover carries a persistent banner spelling out the conflict, so the blocker is visible the moment the popover opens instead of hiding behind a disabled merge button.

### Changed

- **The diff panel shows one continuous spinner from fetch through render.** Opening a diff no longer flashes a spinner, blanks, then flashes a second one while the renderer warms up — it loads in one smooth pass, and a fast cached diff shows no spinner at all.
- **The Active Agents list stays steady.** A finishing agent settling back to idle no longer yanks the whole list around; rows hold their place and glide into new positions only when the order genuinely changes. A new Settings → General → "Auto-sort" toggle (on by default) lets you freeze the list to insertion order instead.
- **The pull-request popover sizes to its content** instead of padding empty space below short PRs.

### Removed

- **The per-pane notification strip is gone.** The amber/green line on individual panes was redundant — panes in the active tab are already on screen — so it's been removed. Project, worktree, and tab roll-up indicators are unchanged.

### Fixed

- **Auto appearance refreshes the whole app again.** Switching Appearance to Auto no longer leaves the terminal palette, window chrome, and sidebar stuck on the previous light or dark scheme; the entire app now follows the system the moment you switch.
- **The Git Viewer no longer flickers on refresh.** Reloading the Changes or History tab keeps the list, its count, and the refresh button on screen while new data loads, then swaps in place — no more blank-and-refill flash.
- **The History tab reloads when you switch worktrees** instead of clearing and staying empty.
- **Worktree row trailing chips line up flush** at the right edge, fixing a ragged margin between rows with and without a PR pill.
- **The Command Palette no longer lists archived worktrees** as switch targets, matching what the sidebar shows.

## [0.3.4] - 2026-05-30

### Added

- **Pull request badges refresh on their own.** While the app is focused, the sidebar and titlebar PR badges pick up remote changes — CI status, review decisions, merges or closes, and freshly-opened PRs — without a manual refresh. Updates arrive faster while checks are still running and ease off once everything settles; polling pauses entirely when the app is in the background.
- **Worktree and tab spinners light up for any running work.** Spinners now turn on both while a bound agent is working and while a plain command (make, npm, pytest, …) runs in the foreground — not only for programs that emit their own progress signal.
- **Close item in the pane right-click menu**, matching ⌘W for a tab that holds more than one pane.

### Changed

- **The diff inspector keeps its open/closed state when you switch worktrees** instead of flipping based on each worktree's remembered setting. It still resets to closed on launch.

### Fixed

- **System appearance no longer gets stuck on the light palette.** In System mode, switching the OS from light to dark (for example at night) now repaints the sidebar chrome immediately instead of waiting for a manual theme toggle.
- **Active Agents status reads only what the terminal shows.** A completion beep or error tone no longer makes a pane look like it's waiting for input; working and blocked state is derived purely from the rendered terminal.
- **Active Agents and worktree-header alignment polish:** status icons right-align consistently in compact mode, the project line lines up under the branch name, and the worktree header spaces evenly when the diff inspector is closed.

## [0.3.3] - 2026-05-28

### Added

- **Branch switcher popover.** Click the branch name in the worktree header to open an inline popover listing every local branch with recent-commit context. Switch branches, rename the current branch in place, or see why a branch is blocked — all without leaving the window. Failed switches surface an inline error banner instead of a silent no-op.
- **History tab in the diff inspector.** A new Changes / History tab pair lives inside the inspector. Selecting a commit renders its full diff in the drawer, the commit message opens in a popover, and the file picker scrolls to the chosen file live.
- **Custom tab icons.** Right-click a tab chip and pick an SF Symbol; the choice persists across launches. Run-script tabs automatically wear a distinct icon so they're recognisable at a glance.
- **Compact mode for the Active Agents panel.** Settings → General toggles between full and compact rows, and the panel restores its open / closed state on next launch.
- **Pull request badge flags merge conflicts.** A PR whose head can no longer merge cleanly into base shows a red warning triangle and red border on its sidebar badge; the hover popover spells out the reason — conflicts, blocked checks, or behind base.

### Changed

- **Worktree header reorganised into two rows** with the pin marker moved next to the branch name; trailing chips slide left smoothly to make room when the diff inspector opens.
- **Diff inspector redesigned.** Icon-based tab picker, sidebar-tinted material background that matches the project window, dedicated close button on the inspector header, smoother drawer transitions, and a calmer file picker.
- **Status-bar bell becomes a hover capsule** with a subtle shake when a new notification arrives.
- **Command-finished notification window widened to 3 seconds**, so a quick keystroke right after the command exits is still treated as user activity instead of registering against the silent prompt.
- **Active Agents row typography is lighter** and the selected row no longer bolds, matching the rest of the sidebar.

### Fixed

- **Active Agents status stays accurate.** A crashed pane now clears its running flag, and an agent that binds while its pane is already in the foreground is detected reliably instead of getting stuck on idle.
- **Diff inspector renderer respects the project theme.** The diff body is transparent so the parent Ghostty background shows through instead of a flat white.
- **Diff Retry actually re-issues the load** instead of leaving the inspector stuck on the error state.
- **History row hover no longer crashes** the popover animator on rapid mouse-over, and history rows respond to a single click instead of needing a double click.

## [0.3.2] - 2026-05-27

### Added

- **Crash reports on release builds.** Crashes are sent to Sentry so post-release regressions can be diagnosed from telemetry instead of needing a repro from the user.
- **Per-project name and accent color in Settings → General.** Rename a project for display and tag it with an accent color; the sidebar and header reflect the change live.
- **Project path under the window title** as a subtitle, so sibling clones of the same repo are distinguishable at a glance.
- **Live color preview in the terminal theme editor.** Adjusting a theme color updates the preview in real time instead of after the panel closes.
- **Active Agents detects more agent kinds**, including agents launched as foreground jobs (no daemon), so the panel reflects what's actually running.

### Changed

- **Window chrome reacts immediately to theme changes.** Sidebar tint, window background, unfocused-split dim, and detail safe-area insets all refresh in place when the Ghostty theme reloads or the system flips between light and dark, without needing to reopen a window.
- **Active Agents panel slides up cleanly from the sidebar footer's top edge** instead of from the window bottom, and no longer paints over the footer or interrupts list scrolling.
- **Theme picker polish in Settings.** Wider hover area, accent-tinted chevron badge, tighter corner radius and right inset, system-style button background, and right-aligned content match the rest of macOS Settings.
- **Window minimum width widened to 800pt** so the project-path subtitle has room to render.

### Fixed

- **Run-script keyboard chord targets the currently selected worktree** instead of an arbitrary one.
- **Settings project name updates on every keystroke** rather than waiting for the field to lose focus.
- **Color panel close no longer applies a stale empty change** when the close callback fires after the panel resets its color.
- **Active Agents status is steadier.** A focused pane no longer flips to "finished" prematurely, and a pane's startup progress now reads as idle before the agent has received any input.
- **Pinned worktree rows drop the orange tint override** in both the sidebar and worktree header so they match the rest of the row treatment.
- **Sidebar list rows no longer bleed under the footer.** The footer adopts the sidebar's material and Ghostty palette so list content can scroll cleanly without showing through.

## [0.3.1] - 2026-05-25

### Added

- **Homebrew install.** `brew install --cask wanggang316/tap/codans` installs the notarized build; the app keeps updating itself through Sparkle.
- **Copy as Pathname / Copy Branch Name** in the worktree right-click menu. The branch entry hides itself for detached-HEAD or folder-only worktrees.

### Changed

- **Agents View row state is steadier.** The working / waiting / finished / idle indicator no longer pins Claude Code panes on "working" when an idle input prompt redraws. Long thinking and streaming stretches still register, and a crashed agent clears itself within 15 seconds.
- **Sidebar and toolbar tone follow the terminal palette.** Window chrome reads light or dark from the active Ghostty background so the sidebar no longer clashes with the terminal.
- **Settings window opens at its compact default size** instead of stretching to fit content.

### Fixed

- **No more black title-bar bleed** when no project is open.
- **Settings → Appearance** no longer paints a system focus ring around the selected theme tile.
- **Pending worktree rows align with their siblings** under the project header instead of sitting flush-left.
- **Agents View sidebar uses the system glass panel material** instead of a flat fill.

## [0.3.0] - 2026-05-24

### Added

- **Active Agents sidebar view.** A new sidebar panel lists every pane currently running a coding agent (Claude Code, Codex, pi, opencode) with a live status — working / waiting for input / finished / idle — and a single click jumps you back to that pane. Settings → General has a toggle (on by default) to auto-open the panel whenever an agent is doing real work.

## [0.2.5] - 2026-05-23

### Added

- Panes restore at the directory you last `cd`'d to, so reopened tabs land where you were working instead of the project root.
- Terminal panes now expose their selection to macOS Accessibility and the Services menu — translators, dictionaries, and hover-to-translate tools can read the selected text from a pane.
- Android Studio in the editor registry, alongside the existing editor choices.

### Changed

- Notification banners lead with `【project · worktree】` so banners from different projects sharing a branch name (`main`, `dev`) are distinguishable.
- Create Worktree sheet seeds its Copy gitignored / Copy untracked / Fetch from origin toggles from per-project and global Worktree settings, instead of always starting unchecked.
- Project Settings → Worktree gains a "fetch from origin on create" override that inherits the global default when left unset.
- `codans worktree new` plants the new worktree in the project's configured worktrees directory by default, matching the GUI's Create Worktree sheet. Pass `--path` to override.
- Inbox rows lead with the project · worktree breadcrumb, fold title and body onto one line below, and reveal the jump arrow only on hover.
- The task-finished notification dot is green instead of yellow; the orange waiting-for-input dot still carries the urgent signal.
- Front-facing product name is unified as **Codans** across menus, About, and Settings.

### Removed

- Project Settings → General Default Shell picker. It had no effect on spawned panes (the resolved shell always fell back to the system default), so it was visual clutter.

### Fixed

- System notification banners play sound again when the user has Sound enabled.
- `codans worktree new` rejects duplicate paths and names instead of stacking orphan rows on retried calls. Pass `--reuse-existing` to make repeated `new` calls idempotent, or `codans worktree rm --by-path <path>` to clean up rows accumulated before the guard.
- `codans pane new` failures now carry a human-readable reason describing what went wrong, and retry once for transient libghostty surface-init races that previously bubbled up an opaque error.

## [0.2.4] - 2026-05-21

### Added

- New notifications surface: when CLI agents finish work or need attention, the matching pane fires a macOS notification, and an unread count rolls up through pane → tab → worktree → status-bar bell so you can find the activity from any level.
- Settings → Notifications pane with per-surface bell visibility toggles (status-bar bell, project, worktree, tab), Dock badge, mute thresholds, macOS permission handling, and an inbox reset action that quarantines suspect entries if anything looks off.
- Mute notifications for a single pane from its right-click menu.
- A worktree with a fresh notification auto-promotes to the front of its project the first time it goes from 0 to 1 unread (toggle in Settings → Notifications).

### Changed

- ⌘⏎ in the terminal now reaches the inner CLI program instead of toggling fullscreen.
- The default-branch marker (the small star identifying the project's main checkout) now leads the worktree row's icon, matching the worktree-header treatment.

### Removed

- Tag-filter button in the sidebar footer — the footer now surfaces sort + refresh only.

### Fixed

- Window chrome no longer paints on top of floating sidebar / panel elements when the app is in fullscreen.
- Restored the halo behind the CI rollup disc on the worktree row icon.

## [0.2.3] - 2026-05-19

### Added

- Sidebar shows diff stats (+N −M) on every worktree, including those without an open pull request.
- Click a worktree's diff-stats chip to open the Git Viewer.
- Filter and sort rows in the sidebar highlight on hover with native macOS selection chrome.
- Appearance footer in Settings links to the Terminal pane.

### Changed

- Auto is now the first option in the Appearance picker.

### Fixed

- Sidebar toggle is back on the window's leading edge, slides the column smoothly, and uses the native macOS control.
- The unfocused split-viewport dim overlay re-tints when switching between light and dark mode.
- The CI rollup glyph adapts to the active theme.

## [0.2.2] - 2026-05-17

### Added

- **Icon-based Appearance picker in Settings → General.** A
  System-Settings-style tile row (Light / Dark / Auto) replaces the
  segmented picker, with previews and an accent-coloured selection
  ring.

### Changed

- **Sidebar is ~20% denser.** Project headers shrink one type step
  and worktree rows tighten their vertical insets so more of your
  work fits on screen.
- **PR-status badge on worktree rows is bolder and easier to read.**
  The CI state fills a coloured disc with a white glyph on top, and
  an unread notification bell now takes priority over the badge so
  it isn't visually buried.
- **Sidebar and detail empty-states cleaned up.** The detail pane
  is a calm blank canvas without the bundle-name title bar; the
  sidebar empty-state is in English with a live shortcut hint and
  an "Open Project" button.
- **Settings → Shortcuts is more legible.** The chord column is now
  plain monospaced text at a larger size with letter tracking and a
  roomier hit area.
- **Shortcut bindings refined.** Toggle Sidebar moves to ⌘⌥S with a
  custom hover tooltip. Back/Forward in Worktree History bind to
  ⌘⌃[ / ⌘⌃] and now also reveal the new selection in the sidebar.
  Reveal in Sidebar moves from ⌘⇧E to ⌘⇧J so it no longer clashes
  with the system Emoji shortcut. The four pane-focus commands are
  renamed to "Focus Pane Left/Right/Up/Down" across menus and the
  command palette.

## [0.2.1] - 2026-05-16

### Added

- **Sort projects in the sidebar.** A new sort glyph next to the
  tag-filter chip offers three modes — join order (default),
  most-active first, and a drag-to-reorder sheet for manual ordering.
- **Worktree branch updates as soon as you `git checkout` in a pane.**
  The sidebar reflects the new branch without needing to refocus the
  app or hit refresh.
- **Configurable update-check interval.** Settings → Updates now
  exposes a 1h / 6h / 12h / 24h dropdown (default 24h), independent
  of the stable / tip channel choice.

### Changed

- **Inbox popover polish.** Each row gains a Project · Worktree
  breadcrumb with a jump arrow; the All / Unread picker stays
  centered; the status-bar bell carries a shortcut tooltip; read rows
  remain as history but are no longer clickable.

## [0.2.0] - 2026-05-15

### Added

- **⌘⇧G opens the current project on GitHub** in your default browser.
- **Worktree folders nest to mirror branch hierarchy.** Branches like
  `feature/foo/bar` now appear under nested folders matching the
  slash structure instead of as a flat list.
- **PR status in the worktree-detail header** mirrors the sidebar
  identity, with diff stats available in a hover popover.

### Changed

- **GitHub PR popover refined.** Merge and Close now share a
  consistent capsule shape, size, and accent treatment.

### Fixed

- **Notification bell clears the unread rollup** when the originating
  pane has been closed.

## [0.1.9] - 2026-05-13

### Added

- **Manual refresh button in the sidebar bottom bar** for triggering an
  immediate project rescan.
- **Folder icon for non-git project worktrees**, distinguishing them
  from git-backed worktrees at a glance.

### Changed

- **Toggle Git Viewer default shortcut is now ⌘G.**
- **Project Options now opens Settings directly** instead of a separate
  sheet. The Settings sidebar auto-expands the matching Project row and
  scrolls to it.
- **Sidebar icons refined.** Lighter git-branch glyph and a smaller,
  bolder main-checkout badge for cleaner alignment.

### Fixed

- **Project-script keyboard shortcuts work reliably** — chord bindings
  no longer get captured by transient menu views.
- **Folder Projects that become git repos upgrade in place** — their
  placeholder worktree picks up the new repo without an app restart.
- **Settings sidebar deep-links jump cleanly** instead of animating the
  scroll.

## [0.1.8] - 2026-05-12

### Added

- **`codans pane send-key`, `send --raw`, `capture`, and `reset`.** New CLI
  commands for sending arbitrary keystrokes, sending raw bytes verbatim,
  dumping the visible buffer, and resetting a pane. `send-key` accepts a
  positional pane id just like `send`.
- **Script run focus toggle.** Scripts can opt their spawned pane in or
  out of taking focus when it appears.
- **Worktree settings.** New global Settings → Worktrees pane plus
  refreshed per-project Settings panes give worktree behavior a proper
  home.
- **Per-project Git Viewer override and Default Git Viewer setting.**
  Pick a Git client per project, or set a global default; ⌘⌥G honors
  the choice.
- **⌘U jumps to the next unread tab.** Check for Updates moves to ⌘⇧U.
- **Spatial pane-focus navigation.** ⌘⌥ arrow keys now route between
  panes by on-screen geometry instead of tree order, so movement matches
  what you see.
- **Empty terminal pane mentions ⌘T** so the keyboard shortcut for a
  new tab is discoverable.

### Changed

- **`codans pane send` and `send-key` no longer steal focus by default.**
  Pass `--focus` to bring the pane forward.
- **Worktrees sidebar icon.** Lighter, stroked git-branch glyph that
  sits better next to the other sidebar rows.

### Fixed

- **Esc reliably dismisses the inbox and other popovers** instead of
  falling through to other handlers.
- **Newly opened, split, and script-spawned panes focus immediately**
  instead of after the next interaction.
- **Split commands anchor on the tab's last-focused pane** rather than
  an arbitrary one.
- **Tab-switch flicker eliminated** under the floating sidebar and
  during the one-frame gap before the terminal warms up.
- **Pane placeholder background matches the terminal theme** instead
  of flashing the system default.
- **Reading a pane no longer changes focus.**
- **Scripts that close their tab or pane on finish honor the policy
  reliably.**
- **Pane redraws after `codans pane reset`** instead of showing the stale
  buffer.
- **Worktree directory path right-aligned** in the project general
  settings.
- **Socket-bind failures surface in the system log** so a stuck `codans`
  is diagnosable.

## [0.1.7] - 2026-05-11

### Added

- **Per-tab accent color.** Choose a color for any tab via right-click →
  Change Color… or ⌘⌥C. A small color dot appears on the chip; the
  close button overlays it on hover. Seven colors matching the macOS
  Finder tag palette, plus a "no color" option to revert.

- **Copy Tab ID / Copy Pane ID.** Right-click a tab or terminal pane to
  copy its unique ID to the clipboard — handy for scripting and
  debugging with `codans`.

### Changed

- **Tab rename shortcut moved to ⌘⌥R** (was ⌘⇧R), freeing the old
  chord for future use.

- **Unread tab indicator** now shows an orange bell icon instead of a
  red dot, reducing visual confusion with tab color dots.

### Fixed

- **DMG installer arrow scaled down** to match the app icon size on the
  install background.

## [0.1.6] - 2026-05-10

### Added

- **Updates pane with channel selection.** New Settings → Updates view
  backed by Sparkle, with a stable/tip channel picker and
  auto-check/download toggles persisted across launches. Menu bar gains
  an Update Channel submenu for quick switching.
- **`codans read` command** prints the visible terminal buffer of a pane to
  stdout.
- **App icon in About window** replaces the generic terminal glyph.
- **Unfocused pane dim now mirrors Ghostty's `unfocused-split`
  appearance** for visual consistency.

### Changed

- **`codans` CLI surface redesigned.** `rpc` subcommand removed, `ls`
  renamed to `tree`, completions hidden, and output hierarchy aligned
  with the Prowl convention.
- **DMG install arrow redrawn as a chevron** to match macOS convention.

### Fixed

- **IPC socket responses no longer truncate on macOS 26.** Clear
  `O_NONBLOCK` on accepted client fds, defer connect to first send to
  dodge the EPIPE quirk, and set `SO_NOSIGPIPE` so write errors surface
  correctly.
- **Tab-bar trailing accessory buttons now show chord hints on hover.**
- **Settings scene receives `CommandKeyObserver`** — opening Updates no
  longer crashes.
- **Pane cursor follows focus on `gotoSplit` navigation** instead of
  lagging behind.
- **`codans tree` / `codans focus` show live working-directory paths** from the
  running Ghostty surface instead of stale state.
- **Archived worktrees hidden from `codans tree` output.**
- **Worktree display-name editing preserves user input** instead of
  reverting to the directory name.
- **DMG volume icon corners rounded with squircle mask.**
- **Appcast feed URL hidden in release builds of the Updates pane.**

## [0.1.5] - 2026-05-07

### Added

- **Drag files into terminal panes to insert shell-escaped paths.**
  Drop one or more files onto a Ghostty surface and their absolute
  paths are inserted at the cursor, properly quoted for the shell.
- **⌘⇧R renames the active tab.** Matches the existing context-menu
  rename action and works through the chord overlay.
- **Pane focus navigation commands.** New `CommandID` entries plus
  menu items for moving focus between panes within a tab, composable
  with the existing chord layer.
- **Keyboard shortcuts shown inline in worktree & project context
  menus** for discoverability without opening the chord overlay.
- **Tab-bar accessory buttons gain hover background and chord
  tooltips.** Each button now exposes its bound chord — resolved
  through the user's keybindings — on hover.
- **DMG installer customized** with a branded volume icon and
  side-by-side Applications layout, so first-launch matches the rest
  of the app.

### Changed

- **Unfocused panes in multi-pane tabs are now dimmed**, mirroring
  the focus treatment used elsewhere in the app.
- **Reveal in Finder rebound to ⌘⌥O**, freeing ⌘O for the project
  picker and matching macOS-wide convention.
- **Window occlusion forwarded to libghostty.** Background windows
  no longer waste GPU on terminal redraws.
- **App icon refreshed**; main-worktree sidebar icon swapped to a
  neutral `circle.circle` glyph that matches regular worktree rows
  in size and tint.

### Fixed

- **Swift 6 isolated-deinit cascade crash on close-tab.** Tab
  teardown no longer trips strict-concurrency deinit checks when
  `SurfaceInfo` is released from `PaneSurface`'s nonisolated deinit
  (an implicit main-actor hop double-freed the TaskLocal scope and
  tripped libmalloc).
- **`Pane.initialCommand` no longer persists across app restarts.**
  Previously a tab restored from disk could re-run its bootstrap
  command, replaying side effects.
- **IME candidate window now follows the cursor**, and backspace
  during composition is suppressed so it edits the candidate buffer
  rather than the terminal.
- **`git diff -M -C` duplicate destination paths** (copy + rename
  collisions) are handled cleanly instead of trapping the parser.

## [0.1.4] - 2026-05-06

### Added

- **Add Project picker can create new folders inline** — the open-panel
  now permits directory creation, so first-time setups don't need to
  pre-make the project directory in Finder.
- **Folder → git auto-promotion.** A folder Project added before
  `git init` / `git clone` is now re-detected as a git repository on
  the next window-focus pulse and its `gitRoot` is persisted. The
  Project gains `+ Add Worktree` and the worktree reconcile path
  without an app restart.

### Changed

- **Worktree "executing" indicator** moved onto the worktree icon slot
  in the sidebar (replaces the previous inline location next to the
  worktree name).
- **ProjectReconciler debounce** raised from 2s to 10s. Window-focus
  freshness still works, but rapid cmd-tab cycles no longer re-scan
  large catalogs every pass.

### Removed

- **Inline loading spinner in Project header.** The reconcile pass is
  fast enough that the brief `ProgressView` next to the Project name
  was visual noise; it flashed on every focus pulse without conveying
  progress.

### Fixed

- **⌘⌫ / ⌘⇧⌫ can no longer archive or delete the main worktree
  checkout.** The sidebar context menu already hid these actions, but
  the destructive chords bypassed the guard. Lifecycle entry points
  now reject archive/remove on the worktree whose path equals
  `project.rootPath`.
- **⌘⌫ / ⌘⇧⌫ are gated on sidebar focus.** When a Ghostty pane holds
  first-responder, the menu items disable and the chord falls through
  to the terminal — restoring the standard ⌘⌫ "delete to start of
  line" in shells and editors.
