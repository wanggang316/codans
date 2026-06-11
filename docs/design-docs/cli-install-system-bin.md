# Design Doc: CLI install — `/usr/local/bin` with bundled binary

**Status:** Draft
**Author:** Claude (autonomous, on behalf of Gump)
**Date:** 2026-04-29
**Amends:** [c4-cli §Decisions D3](c4-cli.md) — was "install into `~/.local/bin/codans` on first launch."

## Context and Scope

The `codans` CLI is the programmable surface of codans (capability C4). For it to be useful, the shell, GUI launchers (Spotlight, app `open`), and cron-like contexts must all be able to find the executable on `PATH` without per-shell setup.

The current installer (`CLIInstallerClient.swift`) places `codans` and a peer `tcode` symlink into `~/.local/bin/` and renders an amber advisory when that directory is not on the running process's `PATH`. Two problems with this surface:

1. **The advisory is noisy and structurally misleading.** The check reads the GUI process's `PATH`, which on macOS comes from `launchd` and never reflects shell rc files. A user who has correctly set up `~/.local/bin` in `~/.zshrc` (so `codans` works in every terminal) still sees "not on PATH" because the GUI process did not source `.zshrc`. Today's repository is a clean repro: `codans --version` works in any terminal, yet the Settings card flags it.
2. **`~/.local/bin` is not on macOS's default `PATH`.** New users — agents driving the published Skill, contractors on a fresh laptop, and anyone using GUI launchers or cron — must manually edit a shell profile before the CLI works. This is exactly the "fix the environment, not the prompt" failure mode that the [Golden Rules](../golden-rules.md) call out.

This doc proposes migrating the install target to `/usr/local/bin`, using a single macOS administrator-authorization dialog to perform the privileged write, symlinking to a binary embedded inside the `.app` bundle, and removing the PATH advisory entirely.

Sibling concerns and constraints:

- The `codans` binary is already embedded into the app bundle at `Contents/Resources/bin/codans` by `scripts/embed-codans.sh` ([Project.swift:240](../../apps/mac/Project.swift)). The binary is signed during release builds along with the app, so the symlink target is already a stable, signed, notarized artifact.
- The existing installer enforces an **atomic install pair** (`codans` + `tcode`), with foreign-file collision detection and rollback. Both behaviours remain valuable — Linuxbrew machines ship an `iproute2`-`codans` and macOS hosts may have a Homebrew `codans` from another tool — and must be preserved.
- The app is **not sandboxed** ([codans.entitlements](../../apps/mac/Configurations/codans.entitlements) is empty). Hardened Runtime is on but does not block the standard AppleScript auth pattern.
- Dev runs use a `CODANS_CLI_BINARY` env override to point at a freshly built `codans` outside the `.app` ([CLIBundleLocator.swift:13](../../apps/mac/CodansCore/CLI/CLIBundleLocator.swift)); this contract is unchanged.

## Goals and Non-Goals

### Goals

- `codans` and `tcode` are reachable from every macOS shell, GUI launcher, and cron-style context immediately after install — no per-shell `PATH` edits.
- Remove the "not on PATH" advisory and its detection code. The state space `installed && !onPath` ceases to exist.
- The symlink target survives app upgrades: a Sparkle update writes a new bundle in place; the symlink target — `Contents/Resources/bin/codans` inside the bundle — keeps resolving to the new binary.
- Preserve atomic pair semantics: `codans` and `tcode` install together, uninstall together, and a foreign file at either path aborts the operation with zero mutations.
- Preserve dev workflow: `CODANS_CLI_BINARY` still wins; debug builds without code signing install as `codans-dev` / `tcode-dev` so they never take over the production `codans`.
- Migrate users off `~/.local/bin/{codans,tcode}` cleanly when the symlinks there are ours.
- Surface privileged failures (user cancelled, auth denied, write failed) with the same `Result<InstallStatus, CLIInstallError>` shape the Settings card already renders.

### Non-Goals

- **Auto-install on first launch.** Install remains user-initiated from the Developer pane; this preserves the [`fewer-permission-prompts`](../../CLAUDE.md) discipline and avoids surprising users with an unexpected admin dialog.
- **Per-user install via `~/bin` or `~/.local/bin`.** Both share the same PATH problem the existing design hit. We pick one location.
- **Multi-app discovery / multi-instance install.** Two codans installs racing for `/usr/local/bin/codans` is the same collision case as homebrew's `codans` — handled by existing collision detection.
- **Privileged helper tool (SMJobBless / EndpointSecurity / SMAppService).** Overkill for a one-shot symlink operation; adds developer-ID provisioning, helper signing, and update complexity for zero user-facing benefit.
- **Auto-edit shell rc files.** Invasive, brittle across zsh/bash/fish/nushell, conflicts with mise/asdf/direnv-style managers, and cannot fix GUI/cron contexts anyway.
- **Custom auth UI.** macOS's native dialog is the bar.

## Design

### Overview

The installer issues **one administrator-authorized shell command per install / uninstall**, executed via in-process `NSAppleScript` so the auth dialog is rendered with the codans app icon and bundle name.

- **Install path:** Release builds manage `/usr/local/bin/codans` and `/usr/local/bin/tcode`; Debug builds manage `/usr/local/bin/codans-dev` and `/usr/local/bin/tcode-dev`. `/usr/local/bin` is on every macOS default `PATH` (`/etc/paths` ships `/usr/local/bin` ahead of `/usr/bin`). A new user — including an agent reading the Skill — gets working `codans` after a single dialog and `Enter`, while local development can install `codans-dev` without disturbing production.
- **Symlink target:** the bundled binary at `Bundle.main.resourceURL/bin/codans`. App moves and Sparkle upgrades preserve this relative path, so the symlink does not need to be re-pointed. `CLIBundleLocator` checks this resource path before any Xcode build-products fallback.
- **Privilege model:** privileged work is one shell-script invocation that does (a) `mkdir -p /usr/local/bin`, (b) `rm -f` only on entries we just verified are absent or our own symlink in a prior unprivileged probe, (c) `ln -s` for any missing entry. The probe is unprivileged and runs every time the Settings card appears.
- **Auth dialog text:** "codans needs administrator access to install the `<command>` command into `/usr/local/bin`." On uninstall: "codans needs administrator access to remove `<command>` from `/usr/local/bin`." `<command>` is `codans` in Release and `codans-dev` in Debug.
- **PATH advisory:** removed. `CLIInstallerClient.isLocalBinOnPath()` and the orange banner in `CLIInstallStatusCard.swift` go away.
- **Status card copy update:** "Installed at /usr/local/bin/codans and /usr/local/bin/tcode." plus a one-line caption: "`codans` is reachable from any shell."
- **Legacy cleanup:** during install, if `~/.local/bin/{codans,tcode}` resolve to our bundle, the same privileged script removes them so users do not accumulate stale entries. Foreign files there are left alone.

### System Context Diagram

```
┌─────────────────────────┐         ┌────────────────────────────────────┐
│ Settings → Developer    │         │ /usr/local/bin                     │
│  CLIInstallStatusCard   │         │   ├── codans      → bundled binary     │
│      │                  │         │   └── tcode   → bundled binary     │
│      │                  │         │   Debug: codans-dev / tcode-dev        │
│      ▼                  │         │                                    │
│  CLIInstallerClient     │         │ codans.app                     │
│      │                  │         │   Contents/                        │
│      │  probe()         │read     │     Resources/bin/codans   (signed)    │
│      ├────────────────────────────►                                    │
│      │                  │         └────────────────────────────────────┘
│      │  install() /     │                  ▲
│      │  uninstall()     │                  │ symlink target
│      │                  │                  │
│      ▼                  │         ┌────────┴───────────────────────────┐
│  PrivilegedShell        │         │ macOS authorization dialog        │
│  (NSAppleScript "do     │ ──────► │  "codans needs admin access…" │
│   shell script … with   │         │  app icon, bundle name, bundle ID │
│   administrator         │         └───────────────────────────────────┘
│   privileges")          │
└─────────────────────────┘

PATH at install time:    /usr/local/bin already on default macOS PATH.
                          No advisory. No rc-file edit. Works in shells,
                          GUI launchers, cron, and out-of-shell agents.
```

### Component Boundaries

```
┌─────────────────────────────────────────────────────────────────────┐
│ CLIInstallerClient (MainActor)                                       │
│  • Paths { tcSymlink: /usr/local/bin/codans,                             │
│            tcodeSymlink: /usr/local/bin/tcode,                       │
│            // Debug defaults: /usr/local/bin/codans-dev and tcode-dev    │
│            legacyLocalBinTc, legacyLocalBinTcode,                    │
│            bundledTcBinary }                                         │
│  • probe()       → InstallStatus            unprivileged, read-only  │
│  • install()     → Result<…, CLIInstallError>  one auth dialog       │
│  • uninstall()   → Result<…, CLIInstallError>  one auth dialog       │
└─────────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ PrivilegedShell (new, nonisolated)                                  │
│  • run(command: String, prompt: String) throws                       │
│      uses NSAppleScript "do shell script … with administrator        │
│      privileges with prompt …"                                       │
│  • Errors:                                                           │
│      .userCancelled            (NSAppleScript errno -128)            │
│      .scriptFailed(stderr)     (any other failure)                   │
└─────────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ CLIFilesystem (existing protocol, used by probe only)                │
│  • Real implementation for production                                │
│  • Test fakes for unit tests                                         │
└─────────────────────────────────────────────────────────────────────┘
```

Dependency direction is unchanged: `App` → `Client` → `Foundation/AppKit`. `CLIBundleLocator` is reused as-is. No new module; `PrivilegedShell` is a small file inside `App/Clients/`.

### API Sketch

```swift
struct CLIInstallerClient.Paths {
    var tcSymlink: URL          // /usr/local/bin/codans
    var tcodeSymlink: URL       // /usr/local/bin/tcode
    var legacyLocalBinTc: URL   // ~/.local/bin/codans        (cleanup target)
    var legacyLocalBinTcode: URL// ~/.local/bin/tcode     (cleanup target)
    var bundledTcBinary: URL?   // Bundle.main.resourceURL/bin/codans
}

enum CLIInstallStatus {
    case unknown
    case notInstalled
    case installed(at: URL, pointsToBundle: Bool)
    case collision(owner: URL)        // /usr/local/bin/codans held by a foreign file
    case failed(CLIInstallError, lastAttempt: Date?)
}

enum CLIInstallError {
    case bundleMissing(URL?)
    case userCancelled                // privileged dialog dismissed
    case scriptFailed(stderr: String) // privileged shell returned non-zero
    case destinationExistsNotOurs(URL)
}

protocol PrivilegedShell {
    func run(_ command: String, prompt: String) throws
}
```

The HomeScope sentinel and `directoryCreateFailed` / `symlinkFailed` cases drop because the privileged path either succeeds or returns a single `scriptFailed(stderr:)`. Probe still classifies `codans` and `tcode` independently; the install pair atomicity now lives inside the shell script (single transaction).

### Privileged shell script

The full script run under admin privs (single `do shell script` call):

```sh
set -e
mkdir -p /usr/local/bin
# Cleanup: only delete a path we already verified (in unprivileged probe)
# is either absent or our own symlink. Foreign files were rejected before
# we got here, so this is safe.
if [ -L /usr/local/bin/codans ]   && [ "$(readlink /usr/local/bin/codans)"   = "<bundled>" ]; then rm /usr/local/bin/codans;   fi
if [ -L /usr/local/bin/tcode ]&& [ "$(readlink /usr/local/bin/tcode)"= "<bundled>" ]; then rm /usr/local/bin/tcode;fi
ln -s "<bundled>" /usr/local/bin/codans
ln -s "<bundled>" /usr/local/bin/tcode
# Legacy cleanup (best-effort, runs in user $HOME via user's auth context;
# stays inside this same dialog because do-shell-script preserves env).
if [ -L "$HOME/.local/bin/codans" ]    && [ "$(readlink "$HOME/.local/bin/codans")"    = "<bundled>" ]; then rm "$HOME/.local/bin/codans";    fi
if [ -L "$HOME/.local/bin/tcode" ] && [ "$(readlink "$HOME/.local/bin/tcode")" = "<bundled>" ]; then rm "$HOME/.local/bin/tcode"; fi
```

`<bundled>` is shell-escaped at compose time. `set -e` ensures partial state is impossible — any failed `ln` or `rm` aborts the dialog with `scriptFailed(stderr:)` and macOS surfaces the system-level error.

The uninstall script is the symmetric subset (only the `rm` lines for non-foreign entries).

## Alternatives Considered

### A1. Detect real shell PATH via login shell, keep `~/.local/bin`

Run `zsh -lic 'echo $PATH'` (or `bash -lic`, `fish -lic`) and use its result instead of the GUI process's `PATH` for the advisory. Removes the false positive but **does not solve the underlying problem**: a fresh-machine user still must edit a shell profile to make `codans` work, GUI launchers and cron still cannot find `codans`, and we add a per-shell fork (~100-300ms) on every Settings render. **Rejected**: fixes the symptom, not the disease.

### A2. Auto-edit shell rc files to add `~/.local/bin` to `PATH`

Append `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`, `~/.bashrc`, `~/.config/fish/config.fish`. Brittle across shell versions, conflicts with mise/asdf/direnv, requires idempotency tracking, leaves stale lines on uninstall, cannot help GUI launchers or cron. **Rejected**: invasive in user files, structurally cannot reach the GUI/cron environment.

### A3. Install into `/usr/local/bin` non-privileged (chown-on-homebrew systems)

On Homebrew machines `/usr/local` is user-owned, so an unprivileged `ln -s` succeeds. On a bare macOS install or on Apple Silicon (Homebrew default `/opt/homebrew`), it fails. **Rejected**: leaks Homebrew assumptions into a tool that targets every macOS host; makes the success state a function of which package manager the user installed first.

### A4. Bundled privileged helper (SMJobBless / SMAppService)

A signed `LaunchDaemon` does the symlink work; the app talks to it over XPC. Industry-standard for tools that perform many privileged operations during a session. **Rejected for this scope**: the workload is one symlink pair per install or uninstall — possibly twice in a user's lifetime per machine. The helper carries permanent costs: separate code-signing and notarization, plist installation under `/Library/LaunchDaemons/`, version negotiation, and the SMAppService UI in System Settings users have to opt into. AppleScript admin auth is the macOS-blessed shape for one-shot privileged ops at exactly this scale.

### A5. `~/bin` instead of `~/.local/bin`

Moves the directory but preserves the PATH problem. **Rejected**: same disease, different name.

### A6. Skip the install card; teach users to alias `codans` to the bundled binary

A `codans` shell function in their rc file would call the bundled binary directly. Defeats the spec ("a coding agent reading the published Skill drives codans exclusively through `codans`") — the agent cannot run a function defined in the user's rc file from a fresh process. **Rejected**.

## Cross-Cutting Concerns

### Security

- **Auth surface.** The single `do shell script … with administrator privileges with prompt …` call is the only privileged code path. `NSAppleScript` runs in-process; the dialog therefore shows the codans icon and bundle ID, not a generic "osascript" prompt. Users see who is asking.
- **Foreign-file safety.** The unprivileged probe still classifies each destination as `absent` / `ourSymlink` / `foreign` before the dialog opens. A `foreign` classification returns `.collision(owner:)` and the dialog is **never shown** — we do not ask for admin rights for an operation we know we will refuse to perform.
- **Shell-injection hygiene.** The bundled binary URL is the only interpolation. It is shell-escaped using single quotes and `'\''` doubling. The script otherwise contains literal paths.
- **Symlink target verification.** Cleanup `rm`s are gated on `readlink == <bundled>` inside the script. A user-replaced `~/.local/bin/codans` pointing at `/usr/bin/sudo` will not be removed.
- **No env trust.** `bundledTcBinary` is resolved via `CLIBundleLocator` from `Bundle.main.executableURL`, not from a user-controllable env var (the dev override is only honored when the env var is set, which a release-built `.app` should never have).

### Migration

- **Old installs.** When the user clicks Install in the migrated Settings card, the privileged script (a) writes the new symlinks under `/usr/local/bin`, (b) deletes legacy `~/.local/bin/{codans,tcode}` only if they resolve to our bundle. Single dialog, two side effects.
- **Skipped explicitly:** silently migrating without the user clicking Install. The user must perform the privileged action; we do not auto-trigger.
- **Legacy uninstall.** A user who had the old installer can also click Uninstall; the same privileged script removes whichever of the four paths are ours.

### Observability

- `Logger(subsystem: "com.gumpw.codans.ui", category: "cli-installer")` already emits `info` on success and `error` on failure. Add: privileged-script `stdout`/`stderr` are captured into `scriptFailed` and logged at `error`.
- The Settings card surfaces success/failure inline; no further telemetry needed.

### Testing

- **Unit tests.** `CLIInstallerClient` retains injectable `CLIFilesystem` and adds an injectable `PrivilegedShell` (default = real). Tests assert the script composed for each scenario (install / uninstall / collision / legacy cleanup) without ever calling the real shell.
- **Integration smoke test.** A `make smoke-cli` target on a developer machine: build app → run install → assert `/usr/local/bin/codans --version` prints the expected version → run uninstall → assert path removed. Documented in the exec plan; not blocked by CI (CI cannot accept the auth dialog).
- **Migration test.** An XCTest creates a tmp `legacyLocalBinTc` symlink, points `Paths.legacyLocalBinTc` at it, runs the installer's compose-script step, and asserts the produced script includes the cleanup line.

### Rollback

- Every operation is **all-or-nothing within one `do shell script`** thanks to `set -e`. A failed `ln -s` aborts before the second `ln -s` runs; the system is left exactly where the script's earlier successful steps left it. The successful prefix is at most: `mkdir -p /usr/local/bin` (idempotent) and the cleanup `rm`s on our own symlinks (also idempotent — re-running install will re-create them).
- Rollback for "the user installs and changes their mind" is just Uninstall.

### Build / Packaging

- No Tuist target changes. `embed-codans.sh` already produces the bundled binary at `Resources/bin/codans`; this design uses that artifact verbatim.
- Code signing: release builds sign `codans` as part of the app bundle (existing). Symlinking does not affect signature; macOS only verifies the bundle, not the symlink.

### Updating the parent design doc

- [c4-cli §Decisions D3](c4-cli.md) is amended to point here. The "Collision check plan for `codans` / `tcode`" section moves install location to `/usr/local/bin` but keeps the same `codans` primary / `tcode` peer logic and the same `which -a codans` detection.

## Risks

| Risk | Mitigation |
|---|---|
| User cancels the auth dialog on Install | `NSAppleScript` returns errno `-128`; surfaced as `.userCancelled`. State unchanged. UI shows "Install cancelled — click Install to retry." |
| Homebrew `codans` (or any other tool) already at `/usr/local/bin/codans` | Existing collision logic returns `.collision(owner:)`; dialog never opens. Card prompts to remove the foreign tool or use `tcode`. |
| User moves the .app after install → bundle path changes → symlink dangles | Probe detects `bundledTcBinary` mismatch via `inspect()`'s "resolved == bundled" check, classifies the symlink as `foreign` (not ours anymore), surfaces as `.collision`. User clicks Retry, confirms a fresh install. Could be auto-healed later; out of scope for v1. |
| `/usr/local/bin` does not exist (bare macOS, Apple Silicon without Homebrew) | Script's `mkdir -p /usr/local/bin` covers it; admin priv allows the create. |
| `NSAppleScript` admin pattern is deprecated in a future macOS | Apple has shipped no replacement and the API is documented through macOS 26. If deprecated, migration to `SMAppService` is a localized change inside `PrivilegedShell.run`. Not blocking. |
| User has a malicious symlink at `/usr/local/bin/codans` whose target is something they should not run | We never invoke the symlink; we only inspect (`readlink`) and replace it. The collision path refuses to overwrite it. |
| Two codans instances installed (e.g. user has /Applications + ~/Applications) | First install wins. The second instance's probe finds a symlink whose target is **its sibling** instance's bundle — classified as `foreign` — and refuses to touch it. User chooses which instance owns `codans` by uninstalling from the other. |

## Open Questions

None blocking implementation.

- *Optional follow-up:* should the Settings card offer "Use `tcode` only (skip `codans` due to collision)" as an explicit one-click resolution? Currently the user must remove the foreign `/usr/local/bin/codans` themselves. Defer to user-research signal; not a v1 ship blocker.
