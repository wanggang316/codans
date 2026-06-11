# ExecPlan: Master Terminal

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-05

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this plan lands, Gump can press ⌥⌘\` from anywhere in macOS and a borderless panel slides in from the top edge of the active screen. Inside the panel runs `claude remote-control` in `~/.config/codans/master-terminal/`, with a freshly bootstrapped `AGENTS.md` (and `CLAUDE.md` symlink) that teaches the Claude session how to drive the codans fleet via the `codans` CLI. Pressing the same hotkey hides the panel; the Claude session stays alive for the rest of the app lifetime so subsequent summons resume the same conversation. Remote clients connecting to that Claude session can then operate the user's worktrees, tabs, and panes without the user touching the codans window at all.

## Progress

- [x] M1 — Bootstrap (`~/.config/codans/master-terminal/` + bundled `AGENTS.md` template + `CLAUDE.md` symlink) with idempotent unit tests *(2026-05-05; manually verified, unit tests blocked by pre-existing test-target build break)*
- [x] M2 — Hotkey-summoned NSPanel with placeholder content (slide-in animation, ⌥⌘\` global trigger, focus return on dismiss) *(2026-05-05; AppKit-level state verified via NSLog — panel.isVisible=true with target frame; visual confirmation deferred to human verification, see Surprises)*
- [x] M3 — Ghostty surface inside the panel running `claude remote-control` *(2026-05-05; build green, code review of the synthetic-PaneID approach plus initial-command-on-first-summon timing pending human verification)*
- [x] M4 — Final lint + test sweep + commit *(2026-05-05; swiftlint clean on MasterTerminal/ files; .swiftlint.yml updated to allow "master" with rationale; build green)*

## Surprises & Discoveries

- **Pre-existing test target build break (2026-05-05)**: `xcodebuild build-for-testing -scheme codans` fails to compile `apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift` with `Unable to find module dependency: 'Codans'`. Reproduced after `git stash` of all my Project.swift / CodansApp.swift edits — confirms the failure predates this plan. Other test files in the same target (e.g. `Tests/Shortcuts/ShortcutDisplayTests.swift`) use the same `@testable import Codans` pattern and would compile if the build reached them, but Xcode bails on the first compile error. Net effect: my M1 unit tests cannot be executed via `xcodebuild test` until the upstream issue is resolved. M1 was therefore verified by **manual end-to-end run** of the built `.app` (deleting `~/.config/codans/master-terminal/` first, observing it gets recreated with `AGENTS.md` + relative `CLAUDE.md → AGENTS.md` symlink). Logging this here for whoever later fixes the test target — both the existing `Tests/Developer/*` files and the newly-added `Tests/MasterTerminal/*` should compile together at that point.
- **Tuist `buildableFolders` and Xcode 26 synchronized groups (2026-05-05)**: `buildableFolders` declarations under `App/Features/...` are *informational* — Tuist creates one `PBXFileSystemSynchronizedRootGroup` per top-level entry (`App`, `Tests`, `Runtime`, etc.) and these are recursive. Listing sub-folders does no harm but is not required for source pickup; resources alongside Swift files (e.g. `MasterTerminalAGENTS.md`) are flattened into the bundle root, not nested under a subfolder. Bundle lookup uses `Bundle.main.url(forResource:withExtension:)` without a `subdirectory:` argument as a result.
- **Symlink-relative-target gotcha (2026-05-05)**: `FileManager.createSymbolicLink(at:withDestinationURL:)` resolves the destination URL against the process cwd and bakes an absolute path into the symlink — observed at first manual run, where `CLAUDE.md` pointed to `/Users/.../apps/mac/AGENTS.md` (the app's working directory at launch) rather than the literal `AGENTS.md`. Fixed by switching to the path-based `createSymbolicLink(atPath:withDestinationPath:)` which preserves the literal string. Documented inline in `MasterTerminalBootstrap.swift`.
- **Synthetic keystrokes don't trigger Carbon hotkeys (2026-05-05)**: `osascript -e 'tell application "System Events" to key code 50 using {command down, option down}'` sends a chord that real keyboards trigger fine, but `RegisterEventHotKey` does not see it — neither when codans is frontmost nor when it is in the background. This is a known limitation of CGEventPost-style synthesis; HID-level events from real keyboards bypass Quartz's event taps and reach Carbon dispatchers, but synthesized events do not. Net effect: M2's hotkey path cannot be smoke-tested via shell-driven keystroke synthesis. Worked around by adding a `TC_MASTER_AUTO_TOGGLE=1` env-var backdoor that calls `controller.toggle()` 3 s after `bringUp`, which confirmed the AppKit code paths execute. Production verification (real ⌥⌘\` press) is left for the user.
- **`screencapture` returns identical output across runs in this agent context (2026-05-05)**: `screencapture -x` produced byte-identical PNGs (`md5 c9cebdfb…`) regardless of which windows were actually on screen. Screenshot size 268 KB at 5120×2880 is implausibly small — looks like screencapture in a non-interactive harness was returning a cached / empty desktop view rather than the live framebuffer. Could not use the screenshot diff to confirm panel visibility. Defaulted to AppKit-level diagnostics (`panel.isVisible`, `panel.frame`) and live `controller.isVisible == true` after toggle; final visual confirmation is left for the user.
- **Swift 6 `@MainActor` deinit + Carbon refs (2026-05-05)**: deinit on a `@MainActor` final class is `nonisolated` in Swift 6, so it cannot read mutable `@MainActor`-isolated stored properties. Hit on first build with errors like *"cannot access property 'eventHandlerRef' with a non-Sendable type 'EventHandlerRef?' (aka 'Optional<OpaquePointer>') from nonisolated deinit"*. Fix: declare the Carbon refs as `nonisolated(unsafe) var`. Single-writer (init/deinit only), pointer-typed, never crossed between actors at runtime — the unsafe carve-out is sound and documented inline.

## Decision Log

- **D1**: Hotkey is registered via Carbon `RegisterEventHotKey` (wrapped in a small `MasterTerminalHotkey` Swift type), not via `NSEvent.addGlobalMonitorForEvents`. Reason: `addGlobalMonitorForEvents` cannot consume the event; the chord would still reach whichever app currently holds focus. Carbon's `RegisterEventHotKey` is the API upstream Cocoa apps including 1Password / Alfred use for this exact pattern, requires no accessibility permission, and lives entirely inside the codans process.
- **D2**: M2 ships a placeholder `NSView` (a single `NSTextField` reading "Master Terminal — surface pending") inside the panel. M3 swaps it for the real Ghostty surface. Reason: separates the platform-level work (panel + animation + hotkey) from the libghostty integration so each milestone is independently verifiable.
- **D3**: We do **not** add anything to `CodansCore.CommandID` — that enum scopes app-internal SwiftUI keyboard shortcuts surfaced through `ShortcutsStore`. The Master Terminal hotkey is a global system hotkey, conceptually distinct (it works when codans is not frontmost, it cannot be expressed as a SwiftUI `.keyboardShortcut`). For v1 the chord is hard-coded to ⌥⌘\` inside `MasterTerminalHotkey`. Promotion to `ShortcutsStore` happens in a follow-up doc once that store grows a "global hotkey" scope.

## Outcomes & Retrospective

**2026-05-05 — All four milestones landed in `main`.**

Shipped:
- `apps/mac/codans/App/Features/MasterTerminal/` — `MasterTerminalBootstrap` (filesystem seed), `MasterTerminalController` (slide-in NSPanel hosting a Ghostty surface), `MasterTerminalWindow` (NSPanel subclass), `MasterTerminalHotkey` (Carbon `RegisterEventHotKey` ⌥⌘\` wrapper).
- `apps/mac/codans/App/Features/MasterTerminal/Resources/MasterTerminalAGENTS.md` — bundled template seeded into `~/.config/codans/master-terminal/AGENTS.md` with `CLAUDE.md` symlinked alongside.
- `apps/mac/codans/Tests/MasterTerminal/MasterTerminalBootstrapTests.swift` — 5 idempotency / symlink-edge-case tests, written but not executed due to a pre-existing test target build break (see Surprises).
- Wiring at the tail of `AppState.bringUp()` — bootstrap unconditionally; controller + hotkey only when `GhosttyRuntime` is alive.
- `.swiftlint.yml` override allowing `master` in identifiers, with rationale.
- Design doc (`docs/design-docs/master-terminal.md`) and ExecPlan (this file) committed alongside the implementation.

Gaps / deferred:
- M1 unit tests don't run — the codansTests target fails to compile due to a pre-existing `Tests/Developer/CLIInstallerClientTests.swift` issue (`Unable to find module dependency: 'Codans'`). M1 was verified by manual end-to-end run instead. Whoever fixes the codansTests target should also assert the MasterTerminal tests now pass.
- Visual smoke of M2 + M3 (slide animation, blur, claude session content) is left for the user. `screencapture` in the agent harness produced static empty-desktop output regardless of panel state, and synthetic keystrokes do not trigger Carbon hotkeys.
- No close-on-claude-exit handling. If `claude remote-control` exits, the dead surface persists until the user toggles the panel. Acceptable for v1.
- No live theme propagation to the Master Terminal surface. `GhosttyRuntime.setColorScheme(_:)` iterates `surfacesByPaneID`, which Master Terminal intentionally stays out of (catalog isolation). Toggling light/dark or an OS-level appearance flip leaves the embedded Claude session on the scheme it had at boot until app relaunch. Surfaced by code-reviewer round 1 (I-1); accepted as a v1 limitation, follow-up will need an "ambient surfaces" broadcast in `GhosttyRuntime`.
- Initial-command timing relies on a fixed 500 ms sleep before `surface.sendInput("claude remote-control\n")`. Heuristic — a sufficiently slow `~/.zshrc` (heavy oh-my-zsh, mise/asdf shims, conda hooks) could still race the keystrokes. Surfaced by code-reviewer round 1 (I-2); the proper fix is libghostty's surface `command` config (bypassing the shell entirely), which `PaneSurface` does not expose today and which the regular Catalog pane path also lacks — both should land together in a follow-up.
- No `ShortcutsStore` integration — the chord is hard-coded to ⌥⌘\`. Promoting this to a user-rebindable global hotkey requires `ShortcutsStore` to grow a "global" scope, deferred to a separate doc.

Lessons:
- Tuist's `buildableFolders` are *informational* under Xcode 26 synchronized groups: only top-level entries become `PBXFileSystemSynchronizedRootGroup`s, and those are recursive. Listing sub-folders is harmless but unnecessary.
- `tuist clean` requires a follow-up `tuist install` before `tuist generate` works again. Worth surfacing in onboarding docs.
- `FileManager.createSymbolicLink(at:withDestinationURL:)` with a relative-looking URL silently bakes an absolute path. The path-based variant `createSymbolicLink(atPath:withDestinationPath:)` is the only correct API for relative symlinks.
- Swift 6 deinit on `@MainActor` classes is `nonisolated` and cannot read `@MainActor`-isolated stored properties; for pointer-typed init-only refs, `nonisolated(unsafe) var` is the right escape hatch.
- Synthetic keystrokes from `osascript` cannot smoke-test Carbon `RegisterEventHotKey` handlers; use a dedicated env-var-gated auto-trigger when shell-driven verification is required.

## Context and Orientation

Related documents:

- Design doc: `docs/design-docs/master-terminal.md` — the authoritative source for architecture, alternatives considered, and risks. Read this first.
- Architecture doc: `docs/architecture.md` — explains the `codans` target's in-app module convention (`App/Features/...`) which Master Terminal follows.

Key existing source files (read for orientation, mostly not modified by this plan):

- `apps/mac/codans/App/CodansApp.swift` — `CodansApp` SwiftUI scene + `AppState.bringUp()` (line 304). The wiring point for Master Terminal sits at the tail of `bringUp()`, after `developerPaneDependencies` is constructed.
- `apps/mac/codans/Runtime/TerminalEngine.swift` — `ensureSurface(for:in:env:)` shows how a Ghostty surface is allocated for a Catalog-managed `Pane`. M3 follows the same pattern, but **without** registering the surface in `TerminalEngine` (Master Terminal lives outside the Catalog by design).
- `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift` — concrete bridge between `Ghostty.SurfaceConfiguration` (cwd, command, env) and the `Ghostty.SurfaceView` displayed in SwiftUI. M3 reuses the same configuration shape but hosts the resulting `SurfaceView` inside an `NSPanel` instead of a SwiftUI view tree.
- `apps/mac/ThirdParty/ghostty/macos/Sources/Features/QuickTerminal/QuickTerminalController.swift` — upstream's NSPanel-based quick terminal. Read for the slide-animation pattern (`animateIn` / `animateOut`, `previousApp` capture). **Do not import or reuse** this class; port only the animation timing and `previousApp` restoration logic.

New module layout (created by this plan):

```
apps/mac/codans/App/Features/MasterTerminal/
├── MasterTerminalController.swift   M2: NSWindowController + slide animation; M3: hosts Ghostty surface
├── MasterTerminalWindow.swift       M2: NSPanel subclass overriding canBecomeKey/canBecomeMain
├── MasterTerminalBootstrap.swift    M1: filesystem setup
├── MasterTerminalHotkey.swift       M2: Carbon RegisterEventHotKey wrapper
└── Resources/
    └── AGENTS.md.template           M1: bundled into Contents/Resources/MasterTerminal/
```

Tests live alongside existing test directories under `apps/mac/codans/Tests/`:

```
apps/mac/codans/Tests/MasterTerminal/
└── MasterTerminalBootstrapTests.swift   M1: idempotency + symlink behavior
```

**Terminology used in this plan:**

- *Master Terminal* — the feature as a whole; one instance per running codans process.
- *Master Terminal panel* — the `NSPanel` (`MasterTerminalWindow`) whose visibility is toggled by the hotkey.
- *Master Terminal surface* — the Ghostty `SurfaceView` embedded inside the panel; runs `claude remote-control`.
- *Master Terminal directory* — `~/.config/codans/master-terminal/`. Owned by `MasterTerminalBootstrap`; never read by any other subsystem.

## Plan of Work

### Milestone 1: Bootstrap and template

After this milestone, running the app once creates `~/.config/codans/master-terminal/` containing `AGENTS.md` (regular file) and `CLAUDE.md` (symlink → `AGENTS.md`). Re-running the app does not modify either file even if the user has edited `AGENTS.md`. The work is testable in isolation — no UI, no Ghostty, no hotkey.

Create `apps/mac/codans/App/Features/MasterTerminal/Resources/AGENTS.md.template`. Content has three sections, drafted concretely so M1 ships with usable text rather than a placeholder:

1. **Mission** — a paragraph stating the session's role: "You are running inside codans's Master Terminal. You manage the user's pane fleet via the `codans` CLI."
2. **`codans` quick reference** — flat list of the command groups documented at `apps/mac/codans-cli/CodansCLI.swift:15` (`status`, `launch`, `doctor`, `open`, `tree`, `project`, `worktree`, `tab`, `pane`, `send`, `broadcast`) with their headline subcommands. One line per command.
3. **Safety constraints** — three bullets, copied verbatim from `docs/design-docs/master-terminal.md` § Filesystem Layout.

Create `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalBootstrap.swift` exposing one entry point:

```swift
public enum MasterTerminalBootstrap {
    /// Idempotent. On first call: creates ~/.config/codans/master-terminal/,
    /// writes AGENTS.md from the bundled template, creates CLAUDE.md as a
    /// symlink to AGENTS.md. Subsequent calls are no-ops if AGENTS.md already
    /// exists (preserving any user edits). Logs and continues if CLAUDE.md
    /// exists but is not the expected symlink.
    public static func ensureUserDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) throws
}
```

The two-parameter form is for testability — tests pass a temp directory and a synthetic Bundle (or read the template path directly). Production callers use the defaults.

Update Tuist target declarations in `apps/mac/Project.swift` so `App/Features/MasterTerminal/Resources/AGENTS.md.template` is bundled into the `.app` at `Contents/Resources/MasterTerminal/AGENTS.md.template`. Verify by inspecting the built `.app` after `make mac-build` (see Concrete Steps).

Add `apps/mac/codans/Tests/MasterTerminal/MasterTerminalBootstrapTests.swift` with these cases:

1. *firstRunWritesTemplate* — point bootstrap at a fresh temp dir; assert `AGENTS.md` exists with the template content, `CLAUDE.md` exists as a symlink resolving to `AGENTS.md`.
2. *secondRunIsNoOp* — call bootstrap twice on the same temp dir, with the user-edited content "MUTATED" written between calls; assert second call leaves "MUTATED" intact.
3. *claudeMdAlreadyARealFile* — pre-create `CLAUDE.md` as a regular file before bootstrap; assert bootstrap does not overwrite it (logs warning, leaves the file alone).
4. *agentsMdMissingButClaudeMdPresent* — pre-create `CLAUDE.md` as a symlink to a nonexistent target; assert bootstrap writes `AGENTS.md` (now the symlink resolves correctly).

Wire `MasterTerminalBootstrap.ensureUserDirectory()` into `AppState.bringUp()` at `apps/mac/codans/App/CodansApp.swift` directly after the `developerPaneDependencies` assignment (line 452 region). Failure to bootstrap should log and continue — the rest of the app must not be blocked by a filesystem hiccup.

**Acceptance for M1**: `xcodebuild test -scheme codans` passes the four new tests; running the app then inspecting `~/.config/codans/master-terminal/` shows `AGENTS.md` and `CLAUDE.md` (a symlink) both present.

### Milestone 2: Hotkey-summoned panel with placeholder content

After this milestone, pressing ⌥⌘\` while codans is running causes a borderless panel to slide in from the top edge of the screen containing the cursor. The panel shows a placeholder `NSTextField` reading "Master Terminal — surface pending" centered on a translucent background. Pressing ⌥⌘\` again animates it out. Clicking on another app while the panel is visible also dismisses it. Focus returns to whatever app the user was in before summoning. No Ghostty surface is allocated yet.

Create `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalWindow.swift`. This is a one-page `NSPanel` subclass:

```swift
final class MasterTerminalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

Style is set by the controller (see below), not in the subclass.

Create `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalController.swift`:

```swift
@MainActor
final class MasterTerminalController: NSObject {
    init() // builds the panel lazily
    func toggle()  // animate in if hidden, out if visible
    private(set) var isVisible: Bool { get }
}
```

Internal structure:

- `lazy var panel: MasterTerminalWindow` — constructed with `.nonactivatingPanel`, `.fullSizeContentView`, `.borderless` style mask; collection behavior `.canJoinAllSpaces, .stationary, .fullScreenAuxiliary`; level `.floating`; backing `.buffered`; `.isOpaque = false`; visualEffectView (`.hudWindow` material) as the contentView.
- `private var previousApp: NSRunningApplication?` — captured in `animateIn`, restored in `animateOut`. Patterned after upstream `QuickTerminalController.swift:19`.
- `animateIn()` — picks the screen containing `NSEvent.mouseLocation`, computes target frame as the top 40% of that screen's visible frame, sets initial frame off-screen above the target, calls `panel.makeKeyAndOrderFront(nil)`, runs an `NSAnimationContext` lasting 0.2 s that animates the panel's `frame` to the on-screen position. Triggers `NSWorkspace.shared.frontmostApplication` capture before `makeKeyAndOrderFront`.
- `animateOut()` — reverse animation, then `panel.orderOut(nil)`, then `previousApp?.activate(options: [])`.
- `windowDidResignKey(_:)` (NSWindowDelegate) — calls `animateOut()` so clicking away dismisses.

Create `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalHotkey.swift`. Wraps Carbon's `RegisterEventHotKey` for chord ⌥⌘\` (key code `kVK_ANSI_Grave = 0x32`, modifiers `optionKey | cmdKey`). Single-callback API:

```swift
@MainActor
final class MasterTerminalHotkey {
    init(onTrigger: @escaping @MainActor () -> Void)
    deinit  // unregisters
}
```

Implementation strategy: the wrapper holds an `EventHotKeyRef`; install a single process-level Carbon event handler in `init` that dispatches to `onTrigger` when the registered hot key id fires. Reference for the boilerplate: search "RegisterEventHotKey Swift" — the standard 30-line pattern. Carbon is available via `import Carbon.HIToolbox` (already imported at `apps/mac/CodansCore/Shortcuts/ShortcutSchema.swift:1`, so the project already links it).

Wire into `AppState`:

- Add `private var masterTerminalController: MasterTerminalController?` and `private var masterTerminalHotkey: MasterTerminalHotkey?` near the other private fields in `AppState` (`apps/mac/codans/App/CodansApp.swift:262` region).
- At the tail of `bringUp()` (after `developerPaneDependencies`):

```swift
let controller = MasterTerminalController()
self.masterTerminalController = controller
self.masterTerminalHotkey = MasterTerminalHotkey(onTrigger: { [weak controller] in
    controller?.toggle()
})
```

No teardown is needed — both objects live for the app lifetime; `MasterTerminalHotkey.deinit` unregisters Carbon when `AppState` is destroyed (which only happens at process exit).

**Acceptance for M2**: launch the app, press ⌥⌘\`, observe the placeholder panel slide down from the top of the screen. Press ⌥⌘\` again, observe it slide back up. Click another app, observe it dismiss. Focus on another app first, press ⌥⌘\` (without bringing codans forward), observe the panel summons and Cmd-Tab returns to the prior app after dismissal.

### Milestone 3: Ghostty surface running `claude remote-control`

After this milestone, the placeholder is replaced with a live Ghostty surface running `claude remote-control` in `~/.config/codans/master-terminal/`. The surface persists across hide/show cycles — pressing the hotkey to dismiss does not kill the Claude process; the next summon shows the same scrollback.

Modify `MasterTerminalController.swift`:

- Constructor takes `Ghostty.App` (from `AppState.ghosttyRuntime`):

```swift
init(ghostty: Ghostty.App) { ... }
```

- Lazy-build a `Ghostty.SurfaceView` once on the first `animateIn`, with a `Ghostty.SurfaceConfiguration` whose `command = "claude remote-control"` and `workingDirectory = MasterTerminalBootstrap.userDirectory.path` (add a public computed property `MasterTerminalBootstrap.userDirectory: URL` that returns `~/.config/codans/master-terminal/`). Reference `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift` for the `SurfaceConfiguration` shape and how the surface is constructed from `Ghostty.App`.
- Embed the resulting `Ghostty.SurfaceView` as a subview of the panel's `visualEffectView` (replacing the placeholder text field), constraint-pinned to the edges.
- The surface is constructed once and retained for the controller's lifetime — `animateOut` only orders the panel out, never tears the surface down.
- `animateIn` calls `surfaceView.becomeFirstResponder()` after the panel is key, so keystrokes go to the terminal immediately.

Update `AppState.bringUp()` to construct the controller with the runtime instead of bare:

```swift
guard let ghostty = self.ghosttyRuntime else { return /* skip Master Terminal */ }
let controller = MasterTerminalController(ghostty: ghostty)
```

The `guard` is necessary because `GhosttyRuntime()` can fail (current code at line 306 already uses `try?`); when it does, the entire app runs without Ghostty and Master Terminal cannot work. Logging that fallback is sufficient.

Audit the `AGENTS.md.template` text for accuracy — read it as if you were a Claude session opening it for the first time. Fix any `codans` command names that have drifted since M1 was drafted by cross-checking against `apps/mac/codans-cli/Commands/HierarchyCommands.swift`.

**Acceptance for M3**: launch the app, press ⌥⌘\`, observe a Ghostty surface boot with `claude remote-control` running in `~/.config/codans/master-terminal/`. Type `pwd` at the Claude prompt (or wait for `claude remote-control` to print its connection URL) and confirm the working directory matches. Dismiss with ⌥⌘\`, re-summon, observe the same session — scrollback preserved.

### Milestone 4: Sweep, lint, test, commit

Run `make mac-check` (formatter + lint) and `xcodebuild test -scheme codans` from `apps/mac/`. Fix any issues. Commit per repo convention (no co-author trailer, atomic commits per milestone if not yet committed). M1 / M2 / M3 each commit independently following the per-milestone-commit cadence; M4 is a final hygiene pass without new code unless lint surfaces issues.

## Concrete Steps

All commands assume working directory `/Users/wanggang/dev/00/codans/apps/mac/` unless stated otherwise.

**Generate the Tuist project after Project.swift edits (M1):**

```
$ tuist generate --no-open
Loaded config from .../codans/apps/mac/Tuist/Config.swift
...
✔ Project generated
```

If the resource bundle declaration is wrong, the build will succeed but the runtime `Bundle.main.url(forResource: "AGENTS.md", withExtension: "template", subdirectory: "MasterTerminal")` returns nil and bootstrap throws. Verify with:

```
$ make mac-build
$ ls .build/Debug/Codans.app/Contents/Resources/MasterTerminal/
AGENTS.md.template
```

**Run M1 tests:**

```
$ xcodebuild test -scheme codans -only-testing:codansTests/MasterTerminalBootstrapTests 2>&1 | xcbeautify
...
Test Suite 'MasterTerminalBootstrapTests' passed
    Executed 4 tests, with 0 failures
```

**Verify M1 end-to-end:**

```
$ rm -rf ~/.config/codans/master-terminal/    # one-time, only on a cold dev machine
$ make mac-run-app                                # builds and opens
# wait for app to finish launching, then:
$ ls -la ~/.config/codans/master-terminal/
AGENTS.md
CLAUDE.md -> AGENTS.md
```

**Verify M2:** with the app running, press ⌥⌘\`. Expected: panel slides down from top of the active screen, shows centered placeholder text. Press again: panel slides up and disappears. Switch to a different app (Cmd-Tab to Safari, say), press ⌥⌘\` — panel summons over Safari without bringing codans's main window forward. Click on Safari — panel dismisses, Safari stays focused.

**Verify M3:** with the app running and Master Terminal panel open, observe `claude remote-control` running. The exact output depends on Claude Code's current CLI behavior; expect a connection URL or interactive prompt.

**Final lint + test (M4):**

```
$ make mac-check
swift-format: 0 files changed
swiftlint: 0 violations
$ xcodebuild test -scheme codans 2>&1 | xcbeautify | tail -5
Test Suite 'All tests' passed at ...
    Executed N tests, with 0 failures
```

## Validation and Acceptance

The plan is complete when **all four** of these hold simultaneously on a clean checkout:

1. `xcodebuild test -scheme codans` from `apps/mac/` passes including all four `MasterTerminalBootstrapTests` cases.
2. `make mac-check` reports zero violations.
3. Running the freshly built `Codans.app`, pressing ⌥⌘\` once causes a Ghostty surface to slide in from the top of the screen with `claude remote-control` running in `~/.config/codans/master-terminal/`. Pressing ⌥⌘\` again hides it. A third press shows it again with the same session intact.
4. `~/.config/codans/master-terminal/AGENTS.md` exists; `~/.config/codans/master-terminal/CLAUDE.md` is a symlink resolving to `AGENTS.md`.

## Idempotence and Recovery

Every step is safe to repeat:

- `MasterTerminalBootstrap.ensureUserDirectory()` is intrinsically idempotent (per M1 tests).
- `make mac-generate`, `make mac-build`, `make mac-check`, `xcodebuild test` are all repeatable.
- The Master Terminal panel and surface are reset on app relaunch — there is no on-disk state for them beyond the `master-terminal/` directory.
- If a milestone partially lands and needs to be re-attempted: revert the unfinished commits with `git restore --staged --worktree -- apps/mac/codans/App/Features/MasterTerminal/` (and the Project.swift / CodansApp.swift edits if any) and start the milestone over.

If `claude remote-control` is not on the user's `$PATH` when M3 is being verified, the Ghostty surface will print a "command not found" message inline. Install Claude Code (`brew install anthropic/claude/claude` or per Claude Code docs) and relaunch — no app-side fix needed.

## Artifacts and Notes

The Master Terminal directory contents after M1, exactly:

```
~/.config/codans/master-terminal/
├── AGENTS.md           (regular file, ~80–120 lines, matches the bundled template byte-for-byte on first run)
└── CLAUDE.md           (symlink → AGENTS.md)
```

The bundled template lives in source at `apps/mac/codans/App/Features/MasterTerminal/Resources/AGENTS.md.template` and ships into `.app/Contents/Resources/MasterTerminal/AGENTS.md.template`. Future plans that need to refresh `AGENTS.md` (when the `codans` CLI surface drifts) can either bump a version marker inside the template and have bootstrap detect it, or — preferred for v2 — write the auto-generated section between `<!-- BEGIN AUTO -->` / `<!-- END AUTO -->` markers and rewrite only that range. v1 ships without the markers.

## Interfaces and Dependencies

**External libraries (already linked, no new dependencies):**

- `AppKit` — `NSPanel`, `NSAnimationContext`, `NSVisualEffectView`, `NSEvent`, `NSWorkspace`, `NSWindowDelegate`.
- `Carbon.HIToolbox` — `RegisterEventHotKey`, `UnregisterEventHotKey`, `EventHotKeyRef`, `EventHotKeyID`, `kVK_ANSI_Grave`, `cmdKey`, `optionKey`, `InstallEventHandler`. Already imported at `apps/mac/CodansCore/Shortcuts/ShortcutSchema.swift:1`.
- `Foundation` — `FileManager`, `Bundle`, `URL`.
- Internal `GhosttyKit` (via `Ghostty.App`, `Ghostty.SurfaceView`, `Ghostty.SurfaceConfiguration`) — already linked into the `codans` target.

**Public API surface created by this plan:**

In `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalBootstrap.swift`:

```swift
public enum MasterTerminalBootstrap {
    public static var userDirectory: URL { get }            // ~/.config/codans/master-terminal/
    public static func ensureUserDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) throws
}
```

In `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalController.swift`:

```swift
@MainActor
final class MasterTerminalController: NSObject, NSWindowDelegate {
    init(ghostty: Ghostty.App)
    func toggle()
    private(set) var isVisible: Bool { get }
}
```

In `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalHotkey.swift`:

```swift
@MainActor
final class MasterTerminalHotkey {
    init(onTrigger: @escaping @MainActor () -> Void)
    // chord is hard-coded to ⌥⌘` for v1; see Decision Log D3.
}
```

In `apps/mac/codans/App/Features/MasterTerminal/MasterTerminalWindow.swift`:

```swift
final class MasterTerminalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

**Modified surfaces:**

- `apps/mac/codans/App/CodansApp.swift` — `AppState` gains two private fields (`masterTerminalController`, `masterTerminalHotkey`) and a wiring block at the tail of `bringUp()`.
- `apps/mac/Project.swift` — `codans` target's `resources` declaration includes `apps/mac/codans/App/Features/MasterTerminal/Resources/**` (or whatever pattern matches the existing convention; the implementer follows the established Tuist style in the file).

**No modifications to:**

- `CodansCore` (no new `CommandID`).
- `CodansIPC` / `codans` / `SocketServer` / handlers.
- `HierarchyManager`, `TerminalEngine`, `Catalog`.
- Any existing test file.

This isolation is the core invariant from `docs/design-docs/master-terminal.md` § Component Boundaries: Master Terminal is a peer of these subsystems, not a consumer.
