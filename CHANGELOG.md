# Changelog

All notable changes to touch-code are documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project does not yet follow semantic versioning — every release until
1.0 is a developer build. Releases are dated.

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

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

- **Homebrew install.** `brew install --cask wanggang316/tap/touch-code` installs the notarized build; the app keeps updating itself through Sparkle.
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
- `tc worktree new` plants the new worktree in the project's configured worktrees directory by default, matching the GUI's Create Worktree sheet. Pass `--path` to override.
- Inbox rows lead with the project · worktree breadcrumb, fold title and body onto one line below, and reveal the jump arrow only on hover.
- The task-finished notification dot is green instead of yellow; the orange waiting-for-input dot still carries the urgent signal.
- Front-facing product name is unified as **TouchCode** across menus, About, and Settings.

### Removed

- Project Settings → General Default Shell picker. It had no effect on spawned panes (the resolved shell always fell back to the system default), so it was visual clutter.

### Fixed

- System notification banners play sound again when the user has Sound enabled.
- `tc worktree new` rejects duplicate paths and names instead of stacking orphan rows on retried calls. Pass `--reuse-existing` to make repeated `new` calls idempotent, or `tc worktree rm --by-path <path>` to clean up rows accumulated before the guard.
- `tc pane new` failures now carry a human-readable reason describing what went wrong, and retry once for transient libghostty surface-init races that previously bubbled up an opaque error.

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

- **`tc pane send-key`, `send --raw`, `capture`, and `reset`.** New CLI
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

- **`tc pane send` and `send-key` no longer steal focus by default.**
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
- **Pane redraws after `tc pane reset`** instead of showing the stale
  buffer.
- **Worktree directory path right-aligned** in the project general
  settings.
- **Socket-bind failures surface in the system log** so a stuck `tc`
  is diagnosable.

## [0.1.7] - 2026-05-11

### Added

- **Per-tab accent color.** Choose a color for any tab via right-click →
  Change Color… or ⌘⌥C. A small color dot appears on the chip; the
  close button overlays it on hover. Seven colors matching the macOS
  Finder tag palette, plus a "no color" option to revert.

- **Copy Tab ID / Copy Pane ID.** Right-click a tab or terminal pane to
  copy its unique ID to the clipboard — handy for scripting and
  debugging with `tc`.

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
- **`tc read` command** prints the visible terminal buffer of a pane to
  stdout.
- **App icon in About window** replaces the generic terminal glyph.
- **Unfocused pane dim now mirrors Ghostty's `unfocused-split`
  appearance** for visual consistency.

### Changed

- **`tc` CLI surface redesigned.** `rpc` subcommand removed, `ls`
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
- **`tc tree` / `tc focus` show live working-directory paths** from the
  running Ghostty surface instead of stale state.
- **Archived worktrees hidden from `tc tree` output.**
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
