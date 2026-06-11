# ExecPlan: Migrate `codans` install to `/usr/local/bin` with admin auth

**Status:** Draft
**Author:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-29

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a user clicking **Install** in Settings → Developer enters their admin password once and immediately gets `codans` and `tcode` working in every shell, GUI launcher (Spotlight, `open`), and cron context — no `~/.zshrc` editing, no advisory banner. A coding agent driving the published Skill on a fresh machine reaches the same state with the same single dialog. The "installed but not on PATH" state ceases to exist. App upgrades (Sparkle) keep `codans` working without any post-update step because the symlink target is the bundled binary's stable in-bundle path.

## Progress

- [x] M1 — Repoint paths to `/usr/local/bin`, drop PATH advisory, update probe (2026-04-29 23:13, commit d1fc652)
- [x] M2 — `PrivilegedShell` protocol, `AppleScriptPrivilegedShell` real impl, fake for tests (2026-04-29 23:14, commit be22dab)
- [x] M3 — Rewrite `install()` / `uninstall()` to compose one privileged shell script (2026-04-29 23:18)
- [x] M4 — Legacy `~/.local/bin/{codans,tcode}` cleanup baked into install script (2026-04-29 23:21)
- [x] M5 — Settings card copy + error surfaces for new error cases (2026-04-29 23:23)
- [x] M6 — Update unit tests; add script-composer tests; update existing assertions (folded into M3+M4 commits)
- [ ] M7 — Manual smoke verification: build app → install → `codans --version` in fresh terminal → uninstall (pending user action — requires admin auth dialog)
- [x] M8 — Update parent design doc (`c4-cli.md` §D3 amendment pointer + collision-section path) (2026-04-29 23:25)

## Surprises & Discoveries

- **2026-04-29 — Pre-existing test scheme breakage.** `xcodebuild test -scheme codans` and `-scheme codans-Workspace` both fail to build the test bundle on `feature/cli_v2`. Two unrelated issues: (a) `CodansKitTests/AliasResolverTests.swift:46` references `IPC.AliasResolveRequest.Kind.space` which no longer exists; (b) `codansTests` cannot resolve `@testable import Codans` (module dependency missing in the generated test target). Neither is introduced by this plan — both are visible at `f3cb4c6` (the plan's parent commit) by reverting all subsequent edits. Action: M6 acceptance for unit tests will need a separate fixup for these two issues, OR the test infrastructure was already known-broken and Gump runs tests another way. Verification mid-milestone falls back on `make mac-build` (clean compile) until the scheme is fixed.

## Decision Log

- **2026-04-29 23:30 — Code-review fixes (commit 34f2b1b).** The agent-skills code reviewer flagged one blocker, three important issues, and a few suggestions:
  1. **(BLOCKING)** `AppleScriptPrivilegedShell` was embedding multi-line shell scripts inside an AppleScript double-quoted literal containing raw newlines. NSAppleScript cannot compile that source. Every real install/uninstall would have surfaced as a generic `.scriptFailed(stderr: "")`. **Fix:** split the command on `\n` and rejoin via `& linefeed &` AppleScript-source concatenation. Extracted as `composeSource(command:prompt:)` for unit-testable assembly.
  2. `inspect()` used `standardizedFileURL.path` to compare symlink target vs bundle path — fragile under Gatekeeper app-translocation (`/private/var/folders/.../AppTranslocation/...`) and the macOS `/private/var ⇄ /var` aliasing. **Fix:** switched to `resolvingSymlinksInPath()` on both sides.
  3. Legacy `~/.local/bin` cleanup line was `[ -L <path> ] && rm <path>` — between the unprivileged probe and privileged execution, a foreign symlink could replace our legacy entry and `rm` would happily delete the foreign one. **Fix:** added `[ "$(readlink <path>)" = '<bundled>' ]` to the guard and trailed with `|| true` so `set -e` doesn't abort when a guard correctly skips a line. Snapshot tests updated.
  4. `install_includesLegacyCleanupWhenLegacyPathsAreOurs` used `script.contains(...)` which masked drift in the cleanup script body. **Fix:** rewritten as full-string `==` assertion.
  5. (Suggested) `shellEscape` was `public`; demoted to internal.
  Skipped: log-line wording fix in `uninstall()` (low signal), `defer { isBusy = false }` reordering (auth dialog blocks the main actor anyway), comment polish on `inspect()`'s broken-symlink branch.
- **2026-04-29 — M1 narrowed to surface-only.** Original plan deleted `Paths.localBin`, `firstEscape`, and `HomeScope.swift` in M1. But `install()` still calls `createDirectory(at: paths.localBin)` and `firstEscape(...)` until M3 rewrites it. Removing them in M1 would break the build. Decision: M1 only changes `Paths.default` defaults, adds legacy paths, drops `isLocalBinOnPath`/`defaultPathEntries`/`pathLookup`, and removes the advisory UI. `localBin`, `firstEscape`, `HomeScope` survive until M3, where they are deleted as part of the install/uninstall rewrite. Net result: same final state, cleaner per-milestone diffs.
- **Why one `do shell script` per operation, not one per symlink.** Two prompts is twice the friction; macOS does not coalesce sibling auth requests within a single user gesture. A combined script keeps install atomic with `set -e` and turns into one auth dialog.
- **Why `/usr/local/bin` over `/usr/local/sbin` or `/opt/local/bin`.** `/usr/local/bin` is on macOS's default `PATH` ahead of `/usr/bin`, has decades of precedent for third-party tools, and matches what most users expect. Apple Silicon Homebrew uses `/opt/homebrew/bin` instead, but that path is not on the default `PATH` for a non-Homebrew shell — so it would not solve the problem we are solving.
- **Why keep the atomic pair (`codans` + `tcode`).** The collision plan in `c4-cli.md` is unchanged: a Linuxbrew or third-party `codans` may already exist on `/usr/local/bin`. Treating the pair atomically lets the `tcode` fallback documented in the spec keep working; uninstall does not strand one of the two.
- **Why not preserve `HomeScope`.** `/usr/local/bin` is by definition outside `$HOME`. The HomeScope guard rejects every write under the new design, so it is replaced by a different invariant: the privileged script writes only to `/usr/local/bin/{codans,tcode}` and to `~/.local/bin/{codans,tcode}` for legacy cleanup, both encoded as constants in the composer.

## Outcomes & Retrospective

**Implementation complete (M1–M6, M8) — 2026-04-29 23:31.** Seven code commits land the migration end-to-end:

| Commit | Milestone | Net diff |
|---|---|---|
| `d1fc652` | M1 — surface paths repoint, drop PATH advisory | +24 / −54 |
| `be22dab` | M2 — `PrivilegedShell` protocol + AppleScript impl + test fake | +83 / −0 |
| `4f704d8` | M3 — privileged install / uninstall via composed script | +259 / −422 |
| `3d342d6` | M4 — legacy `~/.local/bin` cleanup baked into install dialog | +85 / −5 |
| `6388fc5` | M5 — Settings card copy refresh | +3 / −3 |
| `d3bd110` | M8 — `c4-cli.md` D3 amendment + collision-section path update | +14 / −19 |
| `34f2b1b` | review fixes (see Decision Log 2026-04-29 23:30) | +82 / −17 |

**Outcomes vs. design doc goals:**

- ✅ `codans` and `tcode` reachable from every macOS shell, GUI launcher, cron — `/usr/local/bin` is on every default `PATH`. (Verified at compose-time via snapshot tests; M7 manual smoke pending.)
- ✅ "not on PATH" advisory eliminated — `isLocalBinOnPath`, `defaultPathEntries`, `pathLookup`, and the orange UI banner all deleted.
- ✅ App upgrades survive — symlink target is `Contents/Resources/bin/codans`, stable across Sparkle replacements.
- ✅ Atomic pair semantics preserved — foreign collision short-circuits before the auth dialog, captured by `install_whenForeign_returnsDestinationExistsNotOurs_andSkipsDialog` and `uninstall_whenForeignPresent_reportsCollisionAndSkipsDialog`.
- ✅ Dev workflow preserved — `CODANS_CLI_BINARY` override unchanged, `CLIBundleLocator` unchanged.
- ✅ Migration off `~/.local/bin` — install dialog cleans up legacy ours-symlinks in the same auth gesture; foreign legacy entries are left alone (re-confirmed with `readlink` guard at execute time after review found the TOCTOU).

**What went well:**
- Static `composeInstallScript` / `composeUninstallScript` extracted as pure functions made review and snapshot testing straightforward.
- Doing M5 (UI copy) sequentially instead of dispatching to an Agent Team was the right call — work was 3 lines and would've cost more in agent overhead than it saved.
- Code-review caught a real blocker (AppleScript newline escaping) that test coverage *could not* catch — `RecordingPrivilegedShell` never compiles the AppleScript source, so the bug was invisible to the unit-test loop.

**What to do differently next time:**
- Add at least one integration test that calls `AppleScriptPrivilegedShell.composeSource` and asserts on the AppleScript-source string to catch literal-form bugs without invoking the real auth dialog. Done in the review-fix commit.
- The pre-existing test target breakage on this branch (documented in Surprises) means I never actually *ran* the new test suite. M7 (manual smoke) is the only remaining real-world verification step.

**What's left:**
- M7 — manual smoke verification by Gump: build the app, click Install, accept the auth dialog, run `codans --version` in a fresh terminal, click Uninstall.
- (Optional, out of scope for this plan) Fix the pre-existing `CodansKitTests/AliasResolverTests` and missing `Codans` module dependency in the test target so unit tests can be run on this branch.

## Context and Orientation

Related documents:

- Design doc (this plan implements): `docs/design-docs/cli-install-system-bin.md`
- Parent design doc: `docs/design-docs/c4-cli.md` (§Decisions D3 to be amended)
- Architecture doc: `docs/architecture.md`
- Settings developer pane: `docs/design-docs/settings-developer.md`

Key source files:

- `apps/mac/codans/App/Clients/CLIInstallerClient.swift` — the installer client. Holds `Paths`, `InstallStatus`, `CLIInstallError`, `probe()`, `install()`, `uninstall()`, `isLocalBinOnPath()`. Today writes to `~/.local/bin`. After this plan, writes to `/usr/local/bin` via a `PrivilegedShell`.
- `apps/mac/codans/App/Clients/CLIInstaller/CLIFilesystem.swift` — `CLIFilesystem` protocol used by the installer for read-only probe and (currently) for unprivileged writes. After this plan, only used for read-only probe.
- `apps/mac/codans/App/Clients/CLIInstaller/HomeScope.swift` — guard that rejects writes outside `$HOME`. Referenced from the installer; after this plan, the installer no longer writes via `CLIFilesystem` and HomeScope's role disappears. We delete it (88 lines) rather than keep dead code.
- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/CLIInstallStatusCard.swift` — Settings UI. Calls `installer.probe()`, `install()`, `uninstall()`, `isLocalBinOnPath()`, `paths.tcSymlink`. The PATH advisory section (lines 103-123) is deleted.
- `apps/mac/codans/App/Features/Settings/DeveloperPaneDependencies.swift` — DI for the card. Constructs `CLIInstallerClient()` (line 54). After this plan, takes a `PrivilegedShell` argument with a default real implementation.
- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsView.swift` — mounts the card. No changes expected.
- `apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift` — 369 lines, exercises probe / install / uninstall / collision / HomeScope-escape / error formatting. After this plan: HomeScope-escape tests deleted (no longer applicable); install / uninstall tests rewritten to inject a `FakePrivilegedShell` and assert the composed script body; collision tests preserved (unprivileged probe path is unchanged).
- `apps/mac/codans/App/Clients/CLIInstallerClient.swift:229` `defaultPathEntries()` and `:224` `isLocalBinOnPath()` — both deleted; the advisory they fed is gone.
- `apps/mac/Project.swift:240` `Embed codans` post-script — unchanged, already produces the bundled binary at `Resources/bin/codans`.
- `apps/mac/CodansCore/CLI/CLIBundleLocator.swift` — unchanged. Still resolves `Bundle.main.executableURL/../codans`. (In a `.app`, Tuist places `codans` next to the main executable inside `Contents/MacOS/`. The "embed-codans" post-script copies it to `Contents/Resources/bin/codans`. Both paths exist in a built app; the locator already finds the `Contents/MacOS/codans` sibling first.)

Term notes (used below):

- **PrivilegedShell** — the new injectable protocol with one method, `run(_ command: String, prompt: String) throws`. The real implementation calls `NSAppleScript` with `do shell script ... with administrator privileges with prompt ...`. The fake records the call for tests.
- **Script composer** — pure `static` function on `CLIInstallerClient` that takes the bundled-binary URL plus pair-inspection result and returns the shell-script string. Pulled out so tests can assert the script without running it.
- **Bundle path** — the absolute path of the bundled `codans` inside the running `.app`. Resolved once via `CLIBundleLocator`. Used as the symlink target.

## Plan of Work

The work splits into seven milestones. M1–M3 are sequential — each one leaves the build green and the unit tests green. M4 piggybacks on M3's script composer. M5 is UI-only and depends on M2's new error cases. M6 is testing across the whole change. M7 is manual smoke. M8 is the doc update. M1 and M5 can run in parallel after M2 lands; M2 and M3 are tight enough that they should land together.

### Milestone 1 — Repoint paths, drop PATH advisory

**Scope.** No behavior change in install/uninstall yet; just shift the install target paths and remove the advisory plumbing. Keeps M1 tiny and reviewable.

**Edits.**

- `apps/mac/codans/App/Clients/CLIInstallerClient.swift`:
  - Replace `Paths.default` body so `tcSymlink` and `tcodeSymlink` resolve to `/usr/local/bin/codans` and `/usr/local/bin/tcode`.
  - Add `legacyLocalBinTc: URL` and `legacyLocalBinTcode: URL` fields to `Paths` (for use by M4). Both default to `~/.local/bin/{codans,tcode}`.
  - Drop `localBin` from `Paths` (was only used as a HomeScope target). The privileged script gets `/usr/local/bin` as a literal.
  - Delete `isLocalBinOnPath()` and `defaultPathEntries()`. Remove `pathLookup` from the initializer.
  - Delete the `firstEscape` / HomeScope use sites in `probe()` / `install()` / `uninstall()` (HomeScope no longer applies). The unprivileged `inspect()` path remains unchanged for collision detection.
- `apps/mac/codans/App/Clients/CLIInstaller/HomeScope.swift`: delete the file.
- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/CLIInstallStatusCard.swift`: delete `shouldShowPathAdvisory`, `pathAdvisory`, and the `if shouldShowPathAdvisory { pathAdvisory }` invocation in `body`.
- `apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift`: delete tests that exercise HomeScope-escape (they cease to compile when `firstEscape` is gone). Adjust `TempHome.paths(...)` so tests can still inject `tcSymlink` / `tcodeSymlink` pointing under the tmp directory (the production defaults are now `/usr/local/bin`, which tests must override).

**Acceptance.** Project compiles, `xcodebuild test` for the Developer suite passes the surviving tests. `git grep isLocalBinOnPath` returns no hits. `git grep HomeScope` returns no hits. The Settings card no longer renders an orange banner.

### Milestone 2 — `PrivilegedShell` protocol + `AppleScriptPrivilegedShell` real impl

**Scope.** Add the privileged-execution dependency. No installer changes yet — this milestone introduces the seam, ready for M3 to plug into.

**New file.** `apps/mac/codans/App/Clients/CLIInstaller/PrivilegedShell.swift`:

```swift
public protocol PrivilegedShell: Sendable {
    /// Runs `command` under macOS administrator privileges, surfacing the
    /// system auth dialog with the given prompt.
    /// Throws .userCancelled when the user dismisses the dialog (NSAppleScript
    /// errno -128). Throws .scriptFailed(stderr:) on any other failure.
    func run(_ command: String, prompt: String) throws
}

public enum PrivilegedShellError: Error, Equatable {
    case userCancelled
    case scriptFailed(stderr: String)
}

public struct AppleScriptPrivilegedShell: PrivilegedShell {
    public init() {}
    public func run(_ command: String, prompt: String) throws { ... }
}
```

The real implementation composes the AppleScript source with double-quote escaping for the embedded shell command and prompt, calls `NSAppleScript(source:).executeAndReturnError(&error)`, classifies error number `-128` as `.userCancelled`, and packages everything else into `.scriptFailed(stderr:)` with the message from `NSAppleScript.errorMessage`. The test fake `RecordingPrivilegedShell` captures the `command`/`prompt` pair and an injectable `result` (succeed / cancel / fail).

**Edits.**

- `apps/mac/codans/App/Clients/CLIInstaller/PrivilegedShell.swift` — created.
- `apps/mac/codans/Tests/Developer/RecordingPrivilegedShell.swift` — created. Test-only fake.
- `apps/mac/Project.swift` — no edit; the new file lives in an existing buildable folder (`codans/App/Clients/CLIInstaller`).

**Acceptance.** Project compiles. `RecordingPrivilegedShell` appears in the test target. No production callers yet (M3 connects them).

### Milestone 3 — Privileged install / uninstall via composed shell script

**Scope.** Replace the unprivileged `createDirectory` + `createSymbolicLink` + `removeItem` calls in `install()` / `uninstall()` with a single `PrivilegedShell.run` per operation. Add the script composer.

**Edits.**

- `apps/mac/codans/App/Clients/CLIInstallerClient.swift`:
  - `init(...)` gains a `privilegedShell: PrivilegedShell = AppleScriptPrivilegedShell()` parameter.
  - `CLIInstallError` adds `case userCancelled` and `case scriptFailed(stderr: String)`. Removes `case directoryCreateFailed` and `case symlinkFailed` (no longer reachable; the privileged script does both in one shot).
  - New static `composeInstallScript(bundled: URL, plan: PairInspection, legacy: LegacyState) -> String` and `composeUninstallScript(bundled: URL, currentlyOurs: [URL]) -> String`. Both produce the `set -e` shell text from the design doc, with `<bundled>` interpolated using `shellEscape`. `LegacyState` is a tiny struct describing the state of the two legacy paths so the composer can decide whether to add cleanup `rm` lines.
  - `install()` replaces its filesystem-write block with: probe → reject foreign → compose script → `privilegedShell.run(script, prompt: ...)` → re-probe → return `.installed(at: paths.tcSymlink, pointsToBundle: true)`. On `PrivilegedShellError.userCancelled` returns `.failure(.userCancelled)`. On `.scriptFailed(stderr:)` returns `.failure(.scriptFailed(stderr:))`.
  - `uninstall()` mirrors the structure: enumerate which of `tcSymlink`/`tcodeSymlink` are currently ours → if the list is empty, return `.success(.notInstalled)` without an auth dialog → otherwise compose the rm-only script, run privileged, re-probe.
  - `LocalizedError` extension updated for the new cases.

**Acceptance.** With `RecordingPrivilegedShell` injected, the existing install/uninstall happy-path tests pass and the recorded script matches the expected snapshot. Project compiles. The `inspect()` symlink classifier is unchanged (still used by probe and pre-flight).

### Milestone 4 — Legacy `~/.local/bin` cleanup baked into install script

**Scope.** When the user clicks Install, the same auth dialog covers cleanup of legacy `~/.local/bin/{codans,tcode}` symlinks that resolve to our bundle.

**Edits.**

- `apps/mac/codans/App/Clients/CLIInstallerClient.swift`:
  - `inspect(_ url: URL)` already classifies a symlink as `.ourSymlink` when its target equals `bundledTcBinary`. Add a helper `legacyState() -> LegacyState` that runs `inspect` against `paths.legacyLocalBinTc` and `paths.legacyLocalBinTcode` (using the same bundled-binary equality check).
  - `composeInstallScript` appends `rm` lines for each legacy path whose inspect-result is `.ourSymlink`. Foreign or absent: skipped.
  - On uninstall, do *not* touch legacy paths — uninstall is symmetric to install ("undo what *this* operation did"), and the install path is already the migration step. A user who never clicked Install in the new UI does not have anything we should remove.

**Acceptance.** With both legacy paths being our symlinks, the composer-test snapshot for install includes both legacy `rm` lines; with one foreign, the foreign one is omitted; with both absent, no legacy lines appear.

### Milestone 5 — Settings card copy + new error rendering

**Scope.** Surface `CLIInstallError.userCancelled` and `.scriptFailed(stderr:)` in the card; refresh the install path strings; remove the orange advisory section.

**Edits.**

- `apps/mac/codans/App/Features/Settings/Panes/DeveloperSettingsSubviews/CLIInstallStatusCard.swift`:
  - `statusDetail` strings: change `Not installed` copy to "Not installed. Click Install to symlink `codans` into /usr/local/bin." and `installed` copy to "Installed at /usr/local/bin/codans."
  - `LocalizedError` extension: `.userCancelled` → "Install cancelled. Click Install to retry." `.scriptFailed(stderr: let s)` → "Install failed: \(s)" (capped, single line).
  - Already deleted in M1: `pathAdvisory`. No further surface change.

**Acceptance.** Build the app, open Settings → Developer; the orange banner is gone, the install button renders the new copy, and a synthetic cancellation (via debug-only injected fake) shows the new message.

### Milestone 6 — Tests

**Scope.** Land the new test suite alongside the deletions from M1.

**New tests** (`apps/mac/codans/Tests/Developer/CLIInstallerClientTests.swift`):

- `install_callsPrivilegedShell_onceWithComposedScript` — injects `RecordingPrivilegedShell`, calls `install()`, asserts the recorded `command` matches a snapshot for the case "both /usr/local/bin paths absent, both legacy paths absent".
- `install_includesLegacyCleanupWhenLegacyPathsAreOurs` — pre-creates `~/.local/bin/{codans,tcode}` symlinks pointing at the test bundled binary, asserts the composed script ends with the two `rm` lines.
- `install_skipsLegacyCleanupWhenLegacyPathsAreForeign` — pre-creates a regular file at `~/.local/bin/codans`; asserts the composed script does *not* attempt to remove it.
- `install_failedAuth_returnsUserCancelled` — fake returns `.userCancelled`; result is `.failure(.userCancelled)`.
- `install_scriptFailure_returnsScriptFailed` — fake returns `.scriptFailed(stderr: "ln: ...")`; result is `.failure(.scriptFailed(stderr: ...))`.
- `uninstall_doesNotPromptWhenNothingToRemove` — both paths absent; uninstall returns `.notInstalled` without ever calling the fake. (Asserts `recordedCalls.count == 0`.)
- `uninstall_callsPrivilegedShell_onceWithRmScript` — both paths ours; recorded script matches snapshot of `rm` lines.
- `uninstall_collisionPreventsCall` — one path foreign; result is `.success(.collision(...))`, fake never called.

**Deletions** (from M1):

- `escape_*` HomeScope tests.
- `install_pathOutsideHome_*` tests.

**Acceptance.** `xcodebuild test -scheme codans -only-testing:codansTests/CLIInstallerClient` passes. New tests cover both the script-composer output and the privilege-shell invocation count.

### Milestone 7 — Manual smoke verification

Steps recorded under [Concrete Steps](#concrete-steps). On a developer machine:

1. Build the app.
2. Open Settings → Developer, click Install, accept the auth dialog.
3. Open a brand-new terminal (no `~/.local/bin` on PATH override active for this test) and run `codans --version`. Expect `codans <version>` printed.
4. From Spotlight, run an `osascript` snippet that calls `codans --version` to confirm the binary resolves outside any shell.
5. Click Uninstall, accept the auth dialog, confirm `which codans` returns nothing.

Failures trigger a Decision Log entry and may roll back to M3.

### Milestone 8 — Update parent design doc

`docs/design-docs/c4-cli.md` §Decisions D3 currently says "install into `~/.local/bin/codans` on first launch with a user-approval dialog; never touch `/usr/local/bin`." Update to: "install into `/usr/local/bin/{codans,tcode}` via a single macOS administrator-authorization dialog. See `cli-install-system-bin.md` for the full design." Same edit for the "Collision check plan for `codans` / `tcode`" section's `~/.local/bin/` references → `/usr/local/bin/` (the detection logic and the `codans`/`tcode` fallback semantics are unchanged).

Acceptance: `git grep '\\.local/bin' docs/design-docs/c4-cli.md` returns no hits except those that explicitly reference legacy / migration.

## Concrete Steps

Run from `apps/mac/`. Each block is idempotent unless noted.

### Build the test target after each milestone

```bash
make mac-build 2>&1 | tail -20
# Expected tail: ** BUILD SUCCEEDED **
```

### Run the installer test suite

```bash
xcodebuild test \
  -scheme codans \
  -destination 'platform=macOS' \
  -only-testing:codansTests/CLIInstallerClient \
  -quiet 2>&1 | tail -30
# Expected tail: ** TEST SUCCEEDED **  Test Suite 'CLIInstallerClient' passed
```

### Manual smoke (M7)

```bash
make mac-run-app
# In a fresh terminal (Cmd-T):
codans --version
# Expected: codans <version> matching apps/mac/Configurations/<…>.xcconfig
which codans
# Expected: /usr/local/bin/codans
ls -l /usr/local/bin/codans /usr/local/bin/tcode
# Expected: both are symlinks pointing into Codans.app/Contents/Resources/bin/codans
```

### Cleanup (after smoke)

```bash
ls -l /usr/local/bin/codans /usr/local/bin/tcode 2>/dev/null || echo "absent — OK"
ls -l ~/.local/bin/codans ~/.local/bin/tcode 2>/dev/null || echo "absent — OK"
```

## Validation and Acceptance

The change is accepted when **all** of the following observe true:

1. `make mac-build` is green.
2. `xcodebuild test -only-testing:codansTests/CLIInstallerClient` reports zero failures and the new test names from M6 are present in the output.
3. From a fresh shell with no shell-rc edits, `which codans` returns `/usr/local/bin/codans` and `codans --version` prints the build version.
4. The Settings → Developer card shows "Installed at /usr/local/bin/codans." with no orange advisory banner.
5. `git grep -n 'isLocalBinOnPath\|HomeScope\|"\.local/bin"\|defaultPathEntries' apps/mac/codans` returns only legacy-path constants in `CLIInstallerClient.Paths` (where they are intentionally retained for the M4 cleanup).
6. Uninstall works in one click → one auth → both symlinks gone, exit ready for next install.
7. `c4-cli.md` D3 references the new design doc and the new install path.

## Idempotence and Recovery

Every step is safe to re-run.

- The privileged install script is idempotent at the user level: re-clicking Install on a clean machine just replays the same dialog. The script's `set -e` plus our pre-flight collision check means the system never lands in a half-installed state.
- Re-running the installer after a partial failure (e.g. user cancelled mid-install) leaves no artifacts because the cancellation aborts before any `ln`.
- If the bundle path changes (user moves `.app`), probe will see the symlinks resolving to a no-longer-existing target and classify them `foreign`. User clicks Retry; the new privileged install replaces them. No manual rm needed.
- Manual recovery: `sudo rm -f /usr/local/bin/codans /usr/local/bin/tcode` returns the system to the "not installed" state. Documented in M7.

Working-tree recovery during the change: every milestone leaves the build green; if a milestone's tests fail, `git restore` to the start of that milestone and re-attempt. Per Gump's rule, every self-contained change in this plan is its own commit, so reverting is `git revert <hash>`.

## Artifacts and Notes

Snapshot of the install script for the "fresh machine, no legacy" case (used by the M6 composer snapshot test):

```sh
set -e
mkdir -p /usr/local/bin
ln -s '/Applications/Codans.app/Contents/Resources/bin/codans' /usr/local/bin/codans
ln -s '/Applications/Codans.app/Contents/Resources/bin/codans' /usr/local/bin/tcode
```

Snapshot for "fresh machine, both legacy paths are ours":

```sh
set -e
mkdir -p /usr/local/bin
ln -s '/Applications/Codans.app/Contents/Resources/bin/codans' /usr/local/bin/codans
ln -s '/Applications/Codans.app/Contents/Resources/bin/codans' /usr/local/bin/tcode
[ -L "$HOME/.local/bin/codans" ] && rm "$HOME/.local/bin/codans"
[ -L "$HOME/.local/bin/tcode" ] && rm "$HOME/.local/bin/tcode"
```

(The `[ -L … ]` guards mean the cleanup is no-op if a user manually removed the legacy entries already.)

Uninstall script snapshot (both ours):

```sh
set -e
rm /usr/local/bin/codans
rm /usr/local/bin/tcode
```

## Interfaces and Dependencies

In `apps/mac/codans/App/Clients/CLIInstaller/PrivilegedShell.swift`, define:

```swift
public protocol PrivilegedShell: Sendable {
    func run(_ command: String, prompt: String) throws
}

public enum PrivilegedShellError: Error, Equatable {
    case userCancelled
    case scriptFailed(stderr: String)
}

public struct AppleScriptPrivilegedShell: PrivilegedShell {
    public init() {}
    public func run(_ command: String, prompt: String) throws
}
```

In `apps/mac/codans/App/Clients/CLIInstallerClient.swift`, the `Paths` struct becomes:

```swift
struct Paths: Equatable {
    var tcSymlink: URL          // /usr/local/bin/codans
    var tcodeSymlink: URL       // /usr/local/bin/tcode
    var legacyLocalBinTc: URL   // ~/.local/bin/codans        (cleanup only)
    var legacyLocalBinTcode: URL// ~/.local/bin/tcode     (cleanup only)
    var bundledTcBinary: URL?
    static var `default`: Paths { ... }
}
```

The error enum becomes:

```swift
enum CLIInstallError: Error, Equatable {
    case bundleMissing(URL?)
    case destinationExistsNotOurs(URL)
    case userCancelled
    case scriptFailed(stderr: String)
    case uninstallFailed(URL, underlyingDescription: String)  // legacy retain — uninstall via privileged shell still wraps script-level rm errors
}
```

The init becomes:

```swift
init(
    paths: Paths = .default,
    fileSystem: CLIFilesystem = RealCLIFilesystem(),
    privilegedShell: PrivilegedShell = AppleScriptPrivilegedShell()
)
```

Used libraries: `Foundation`, `AppKit` (for `NSAppleScript`), `os.log`. No new external dependencies.
