# ExecPlan: Redesign `codans` CLI Surface

**Status:** Completed
**Author:** Codex
**Date:** 2026-05-09

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, `codans` exposes a smaller, more predictable command surface aligned with <https://clig.dev/>: concise help, consistent verbs, machine-readable JSON on stdout, human diagnostics on stderr, and clear exit codes. The CLI is not backward compatible with the old command names. It remains a stateless thin RPC client over the existing `CodansIPC` methods.

## Progress

- [x] Review current CLI implementation and clig.dev guidance — 2026-05-09
- [x] Choose Option A: redesign CLI surface while preserving app-side IPC — 2026-05-09
- [x] Add testable command helper logic — 2026-05-09
- [x] Replace top-level command surface and split command files by resource — 2026-05-09
- [x] Regenerate shell completions — 2026-05-09
- [x] Validate with tests, build, and lint — 2026-05-09

## Surprises & Discoveries

- The current CLI uses ArgumentParser and a shared renderer already, but most hierarchy, terminal, tag, and RPC commands live in one large `HierarchyCommands.swift` file. The main risk is not parser technology; it is information architecture and drift-prone command implementation.
- Running `xcodebuild` against `codans.xcodeproj` skips SwiftPM dependencies generated into the workspace. CLI validation must use `codans.xcworkspace`, otherwise `ArgumentParser` cannot be resolved.
- The first `make mac-generate` in this worktree built Ghostty and took several minutes. Subsequent `codans` and `CodansKit` builds were incremental.
- Repository-wide SwiftLint is currently blocked by pre-existing app and core test violations outside the redesigned CLI surface. A changed-file SwiftLint pass was used to validate this CLI patch.
- Manual CLI testing exposed two follow-up issues: `codans send --stdin` could wait on terminal stdin when text arguments were also present, and the app IPC server was not binding a live terminal input sink, so `terminal.sendInput` always reported no Ghostty runtime.
- Follow-up comparison with Prowl and Supacode showed the redesigned CLI still made discovery too stepwise. Prowl's effective pattern is a single tree listing plus current-pane defaults for terminal control; Supacode keeps resource groups but relies on focused context for common actions.

## Decision Log

- **DEC-1:** Keep `CodansIPC` method names and app-side handlers unchanged. This limits the blast radius to the CLI and avoids coupling a UX redesign to socket server behavior.
- **DEC-2:** Prefer singular resource command groups for every entity operation, including list (`codans project list`, `codans worktree list`, `codans tab list`, `codans pane list`). Keep `codans tree` as the cross-entity discovery shortcut.
- **DEC-3:** Remove shell-completion generation from the public command surface, and expose common app status commands at the top level (`codans status`, `codans launch`, `codans doctor`).
- **DEC-4:** Remove the `codans rpc` escape hatch from the public CLI surface. The typed command tree is the supported interface; raw RPC access is kept internal.

## Outcomes & Retrospective

The CLI now presents a resource-oriented, clig.dev-aligned command tree:

- App commands: `codans status`, `codans launch`, `codans doctor`.
- Resource list commands: `codans project list`, `codans worktree list`, `codans tab list`, `codans pane list`.
- One-shot discovery: `codans tree` lists Projects, Worktrees, Tabs, and Panes in one hierarchy.
- Mutation command groups: `codans project`, `codans worktree`, `codans tab`, `codans pane`.
- Terminal IO commands: `codans send` and `codans broadcast`, both with `--stdin` support.
Raw RPC access is intentionally not exposed as a CLI command.

The app-side IPC protocol was intentionally preserved. The old CLI surface is removed rather than shimmed.

Follow-up testing hardened the first-run CLI behavior:

- `codans send` and `codans broadcast` now reject mixed text arguments plus `--stdin` before reading stdin.
- `--stdin` now reports a clear error when stdin is an interactive terminal instead of blocking indefinitely.
- The running app now binds `terminal.sendInput` to `TerminalEngine` when Ghostty runtime is live, so CLI terminal input reaches app panes after rebuilding and relaunching the app.
- `codans send` now follows Prowl's common case: one argument sends text to the current pane, two arguments are target plus text, `-p/--pane` supplies an explicit target, and trailing Enter is sent by default unless `--no-enter` is set.
- `codans pane focus <pane-id>` and related pane locator commands now infer Project, Worktree, and Tab from the catalog when a pane id is enough.
- The terminal Enter byte is now carriage return (`\r`), matching terminal input semantics. Plain newline could visibly wrap without executing the command in Ghostty-backed panes.
- `tag` and `tags` are not part of the current CLI surface.

## Context and Orientation

Related documents:
- Architecture: `docs/architecture.md`
- Original CLI design: `docs/design-docs/c4-cli.md`
- Completed CLI implementation plan: `docs/exec-plans/0003-hooks-and-cli.md`

Key source files:
- `apps/mac/codans-cli/CodansCLI.swift` — ArgumentParser root and global options.
- `apps/mac/codans-cli/Commands/HierarchyCommands.swift` — current large command aggregate; to be replaced by resource-specific files.
- `apps/mac/codans-cli/Commands/SystemCommand.swift` — current system command group and shared CLI session/error helpers.
- `apps/mac/codans-cli/Commands/OpenCommand.swift` — editor handoff command; retained with clearer top-level help.
- `apps/mac/CodansKit/Transport/RPCClient.swift` — shared JSON-RPC client; unchanged except for any small helper additions needed by tests.
- `apps/mac/CodansKit/Render/Renderer.swift` — shared stdout renderer; unchanged unless needed for clig.dev output consistency.

## Plan of Work

Milestone 1 creates small pure helpers for command text handling so parser behavior that does not require a socket can be tested in `CodansKitTests`. This includes joining variadic command text and validating exactly-one scope rules.

Milestone 2 replaces the command surface. The new root commands are `status`, `launch`, `doctor`, `open`, `tree`, `project`, `worktree`, `tab`, `pane`, `send`, and `broadcast`. List operations live under their singular entity groups, e.g. `codans project list` and `codans pane list`.

Milestone 3 splits implementation files by resource: system/app commands, projects, worktrees, tabs, panes, terminal IO, and open. Shared CLI session and error handling move out of `SystemCommand.swift` into a common file.

Milestone 4 regenerates bash, zsh, and fish completion resources from the new ArgumentParser tree.

## Concrete Steps

Run from repository root:

```bash
xcodebuild test -scheme CodansKit -destination 'platform=macOS'
xcodebuild build -scheme codans -destination 'platform=macOS'
make mac-lint
```

If generated Xcode project state is stale, run:

```bash
make mac-generate
```

## Validation and Acceptance

Acceptance:
- `codans --help` lists the redesigned top-level commands.
- `make regen-completions` uses ArgumentParser's hidden `--generate-completion-script` flag to refresh bundled completion resources.
- `codans send` and `codans broadcast` preserve existing RPC behavior while adding stdin-friendly argument handling.
- JSON mode remains stdout-only and error paths remain stderr-only.
- `CodansKit` tests pass and `codans` builds.

## Idempotence and Recovery

The work is source-only and can be repeated safely. Completion files are generated artifacts from the current command tree and may be regenerated after any parser change. No persistence migration is involved.

## Artifacts and Notes

- Replaced `apps/mac/codans-cli/Commands/HierarchyCommands.swift` and `apps/mac/codans-cli/Commands/SystemCommand.swift` with smaller resource-specific command files.
- Added `apps/mac/CodansKit/CLIArgumentHelpers.swift` and focused parser/helper tests.
- Regenerated `apps/mac/codans-cli/Resources/completions/codans.bash`, `codans.fish`, and `codans.zsh`.
- Validation passed:
  - `xcodebuild test -workspace codans.xcworkspace -scheme CodansKit -destination 'platform=macOS'`
  - `xcodebuild build -workspace codans.xcworkspace -scheme codans -destination 'platform=macOS'`
  - `xcodebuild build -workspace codans.xcworkspace -scheme codans -destination 'platform=macOS'`
  - Changed Swift files linted with SwiftLint script input mode.
  - Built `codans --help` shows the redesigned top-level commands.
  - Built `codans send -h` documents current-pane targeting, target-plus-text usage, and `--no-enter`.
  - Built `codans tree -h` documents one-shot hierarchy discovery.
  - `make regen-completions` refreshes bundled completion scripts for the redesigned command tree.
- `CodansTests` targeted app tests could not be run through the current `codans` scheme because the test target is not included in the selected scheme/test plan.
- Repository-wide `make mac-lint` still fails on unrelated existing violations under `codans/App/...` and `CodansCoreTests/...`.

## Interfaces and Dependencies

Use Apple ArgumentParser for all parser behavior. Continue using `CodansKit.RPCClient`, `CodansKit.Renderer`, `CodansCore`, and `CodansIPC`; do not import app-side modules from `codans`.
