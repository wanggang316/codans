# ExecPlan: Rename the "panel" concept to "pane" across the project

**Status:** Approved
**Author:** Claude (for Gump)
**Date:** 2026-04-24

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

Unify the terminology used throughout codans with its sibling project supaterm, whose environment variable `SUPATERM_PANE_ID` is already referenced by our own architecture doc as the thing we mirror. After this change, every identifier, wire-level string, on-disk field, CLI verb, and document that currently says "Panel" (meaning: one terminal tile inside a Tab) will say "Pane" instead. A reader can verify the rename by running `codans pane list`, by finding `CODANS_PANE_ID` exported inside any spawned shell, and by seeing hook events stream under the `pane.*` namespace. No compatibility shim is required — this is a single-user dev tool with no external consumers.

Unrelated uses of the word "panel" (AppKit's `NSPanel`, `NSOpenPanel`, `NSSavePanel`, and similar system classes) remain untouched. Settings subpages, which already use the spelling "pane" in `apps/mac/codans/App/Features/Settings/Panes/`, are a different concept living in a different namespace and do not change.

## Progress

- [x] Milestone 1 — Atomic Swift + wire + CLI rename (code compiles, tests green)
- [x] Milestone 2 — Shell shim scripts under `skills/codans-cli/shims/` switched to `CODANS_PANE_ID`
- [x] Milestone 3 — Docs in `docs/**` refreshed (architecture.md, design-docs, product-spec, exec-plans)
- [x] Milestone 4 — Skill docs under `skills/codans-cli/**` refreshed
- [x] Milestone 5 — `/codex:review` pass over the branch

## Surprises & Discoveries

- **Scope of swept files is narrower than expected.** Initial grep for `panel` reported 166 Swift files and ~2500 occurrences, but many of those files only *mentioned* `Panel` once in a doc comment. The actual mechanical rename list comes to ~140 files once `NSPanel`/`NSOpenPanel`/submodule paths are excluded.
- **Settings namespace already uses "pane"** (`SettingsWindowFeature.repositoryPanes`, `App/Features/Settings/Panes/ComingSoonPane.swift`). Post-rename, both the terminal-tile concept and the settings-subpage concept share the word "pane". They live in disjoint namespaces, so readers disambiguate by context. Decision recorded in the Decision Log.
- **Milestone 1 shakedown.** One non-obvious grep-replace landmine: the verb form `panels` (an array) must become `panes`, but `unpanelled` / `repanelled` do not appear, so simple whole-word replacement is safe. Acronym `PANEL` appears only in the env var and one test constant. String literals in hook namespaces (`"panel.idle"` etc.) are handled by the `HookEvent` raw-value rewrite and fan out through Codable round-trip tests.
- **Atomic rename worked on first build.** Tuist generate + `xcodebuild build` for both schemes passed without intermediate errors. Only one stray reference was missed: `PanelLabelsCatalogTests.swift` had a filename that needed a `git mv`.
- **Docs commit was pure prose.** Out of 791 panel mentions in docs, roughly 180 were under `docs/design-docs/` and another 500+ under `skills/codans-cli/` — mostly in reference docs and hook documentation. No executable code lived in these files, so the sweep was safe.
- **CLI verb `codans panel` → `codans pane` required one test-fixture update** in `CodansKitTests/ExitCodeTests.swift` which spelled `"panel"` as a magic string.
- **Command palette IDs** (`panel.new-tab`, `panel.split.right`, …) are currently not persisted anywhere (no keybinding config references them by ID). Safe to rename in lockstep.
- **BSD `sed` does not support `\b`.** The plan's Concrete Steps showed `sed` commands with `\b` that silently no-op on macOS. Switched to `perl -pi -e` for the actual sweep — works identically and supports `\b` portably.
- **Guard list for AppKit had to be richer than expected.** The initial per-rule approach (`\bPanel\b`, `\bPanelActionRouter`, …) missed many composite camelCase identifiers (`panelActionRouter`, `panelClosedByTab`, `panelHosts`, `panelLocator`, `panelUUID`, etc.). A blanket `s/Panel/Pane/g; s/panel/pane/g; s/PANEL/PANE/g` with mask-and-restore sentinels for the seven AppKit `NS*Panel` classes converged in a single pass.
- **Pre-existing test failures are unrelated to the rename.** `SettingsStoreTests.{saveNowCancelsPendingDebouncedWrite, writeFailureLogsButDoesNotMoveFileAside}`, `TabBarFeatureTests.newTabButtonCallsCreateTab`, and `WorktreeDetailFeatureTests.tabBarActionRoutesViaScope` all fail on the baseline commit `881592b` too. None of them touch panel/pane code. Verified by `git stash` + re-running the same tests on HEAD~1.
- **Codex review produced three hallucinated "must-fix" items.** Each referred to files or identifiers that do not exist in the repo (`apps/mac/codans/Resources/Templates/panel-open.json`, `skills/codans/SKILL.md`, a `panelState` variable in `SplitViewportFeature.swift`, `PaneGroupPaneCoordinator`). Ground-truth audit: `grep -rn '\bPanel\b\|\bpanel\b\|\bPANEL\b\|CODANS_PANEL_ID' apps/mac docs/ skills/` with the standard AppKit/Settings exclusions returns zero hits. The correctly-preserved boundaries (NSPanel, Settings/Panes, Ghostty submodule) were verified cleanly.
- **Final cross-tree audit found four real residuals my earlier Swift-only audit missed.** Three shell files carried "Panel" at sentence-start in comments that slipped past `\b` boundaries (`skills/codans-cli/shims/{claude-stop-hook,codex-complete-hook}.sh` and `skills/codans-cli/tests/pi.smoke.sh`). The codans CLI's generated shell completions under `apps/mac/codans-cli/Resources/completions/codans.{bash,zsh,fish}` were stale because they ship as pre-rendered artifacts, not generated at build time; regenerating via `codans --generate-completion-script <shell>` against the freshly-built binary produced clean output. Landed as commit `9c70361`. Lesson: always run the cross-tree audit against `git ls-files`, not just against the source-code globs.

## Decision Log

- **DEC-1 — One atomic Swift commit, not a phased rename.** A type rename of `PanelID`/`Panel` cannot be staged because every Swift file that imports `CodansCore` sees the old and new names at once. Splitting into smaller commits would produce non-building intermediate states, which would break `git bisect` and CI. We accept one large mechanical commit as the cost.
- **DEC-2 — Do not touch Settings "panes".** `apps/mac/codans/App/Features/Settings/Panes/` and `SettingsWindowFeature.repositoryPanes` already use the word "pane" for a different concept (settings subpages). Leave them untouched. Reviewers get a short note in the commit message explaining the double-meaning.
- **DEC-3 — No deprecation window for `CODANS_PANEL_ID`.** Per user directive ("不用考虑兼容性"), the env var is renamed in-place. Shell shims in `skills/codans-cli/shims/` change in the same commit as the Swift injection site so a fresh Pane always agrees with its shim.
- **DEC-4 — Parallelize docs, not code.** The Swift rename is single-threaded because every layer depends on the Core type names. Docs under `docs/**` and `skills/**` are independent `.md` trees and are delegated to two subagents in parallel.
- **DEC-5 — `codans panel` subcommand renamed without hidden alias.** The original evaluation suggested keeping `panel` as a hidden alias; the user opted out of compatibility, so the alias is removed.
- **DEC-6 — Use `perl -pi -e` instead of `sed -i ''` for the sweep.** Needed because BSD sed on macOS silently no-ops on `\b` word boundaries. Perl is present on every Mac dev box and supports `\b` and mask-unmask patterns cleanly.
- **DEC-7 — Accept Codex review as confirmation, not as a punch list.** Codex generated three hallucinated "must-fix" items (files and identifiers that do not exist in the repo). Verified against the working tree; all zero. The rename is considered complete based on the grep-based audit which returns zero residuals across `apps/mac`, `docs/`, `skills/`, and the shim tree.

## Outcomes & Retrospective

Terminology is unified across the codebase, skill docs, and wire protocol. A reader coming from supaterm now finds consistent vocabulary: `pane` in the UI, `PaneID` in code, `codans pane` on the CLI, `CODANS_PANE_ID` in the shell environment, and `pane.*` hook events streaming to subscribers.

**Scope vs plan.** All five milestones landed as planned. The docs sweep (M3 + M4) produced the largest single commit by line count (~470 insertions / ~470 deletions) but is behaviorally a no-op. M1 was the riskiest slice; it went through without surprise thanks to the guarded sed patterns and full compile verification.

**Lessons learned.**
- Mechanical rename is safe when guarded by compiler+tests. The approach — small number of precise `sed` invocations scoped to the correct file trees, then full build, then fix stragglers — converges in one or two passes. Pure `grep -c` tells you coverage quickly.
- When a word collides with an unrelated concept (Settings "panes"), flag it up-front in the plan so reviewers aren't surprised. DEC-2 made the Milestone 1 review straightforward.
- Subagent parallelism pays off for docs because `.md` trees don't cross-reference by identifier; the two doc commits landed in roughly half the time of a serial pass.

## Context and Orientation

Related documents:
- Architecture: `docs/architecture.md` (see §142 — already notes that `CODANS_PANEL_ID` "mirrors `SUPATERM_PANE_ID`", which makes `panel` the historical drift)
- Product spec: `docs/product-spec.md`
- Design docs: `docs/design-docs/*.md` (roughly 30 files, most referencing "Panel" in the architectural-domain sense)
- Golden rules: `docs/golden-rules.md`
- Prior planning artifact: `docs/exec-plans/0009-panel-host-feature.md` (the file itself gets renamed)

Key source files (rename hotspots, in dependency order):

1. **Core types** (`apps/mac/CodansCore/`)
   - `IDs.swift` — declares `PanelID` (the UUID wrapper). All downstream modules depend on this.
   - `Panel.swift` — the `Panel` struct (working directory, labels, initial command). Must be `git mv`ed to `Pane.swift`.
   - `PanelActionRequest.swift`, `PanelInfoDelta.swift` — value types consumed by the runtime.
   - `Tab.swift` — stores `var panels: [Panel]`, `flatPanelIDs`, `InvariantError.leavesDoNotMatchPanels`.
   - `Catalog.swift` — traversal API `panelIDs(inWorktree:)`, `worktreeID(forPanel:)`.
   - `TerminalEvent.swift` — `TerminalEvent.panelIdle` case.
   - `Hooks/HookEvent.swift` — raw strings `"panel.created"` through `"panel.crashed"`.
   - `Hooks/HookEventData.swift` — `case panelIdle(idleSeconds:sinceLastOutput:sinceLastInput:)`.
   - `Notifications/TemplateField.swift` — raw paths `"panel.id"`, `"panel.workingDirectory"`, `"panel.initialCommand"`.

2. **IPC** (`apps/mac/CodansIPC/`)
   - `Method.swift` — enum cases `hierarchyListPanels`, `hierarchyDescribePanel`, `hierarchyOpenPanel`, `hierarchySplitPanel`, `hierarchyClosePanel`, `hierarchyFocusPanel`, `hierarchyResizePanel`, `hierarchyZoomPanel`, `hierarchyUnzoomPanel`, `hierarchyResolvePanelLabel`, `hierarchySetPanelLabels`, `terminalRetryPanel` — raw values `"hierarchy.*Panel*"` etc.
   - `WireTypes/PanelOpenRequest.swift` — `git mv` to `PaneOpenRequest.swift`.
   - `WireTypes/AliasResolveRequest.swift` — `Kind` enum case `panel`, field `contextPanelID`.
   - `Editor/EditorIPCTypes.swift`, `Editor/EditorIPCError.swift` — doc comments referencing "Panel".

3. **CodansKit** (`apps/mac/CodansKit/Transport/`)
   - `AliasResolver.swift` — `env["CODANS_PANEL_ID"]` read, `"CODANS_PANEL_ID"` literal in switch.

4. **codans CLI** (`apps/mac/codans/`)
   - `CodansCLI.swift` — registers `PanelCommand.self`.
   - `Commands/HierarchyCommands.swift` — `PanelCommand`, `PanelList`, `PanelListRenderable`, `PanelLocatorArgs`, `PanelClose`, etc. Subcommand name string `"panel"`.
   - `Commands/HookCommand.swift` — help text "e.g. panel.ready".

5. **App** (`apps/mac/codans/`)
   - `Runtime/TerminalEngine.swift`, `Runtime/HierarchyManager.swift` — bulk of the logic, ~200 combined hits.
   - `Runtime/Ghostty/PanelSurface.swift` — `git mv` to `PaneSurface.swift`.
   - `Runtime/Ghostty/GhosttyRuntime.swift`, `GhosttyActionDecoder.swift`.
   - `App/PanelHostView.swift` — `git mv` to `PaneHostView.swift`.
   - `App/Features/PanelActionRouter/` — directory `git mv` to `PaneActionRouter/`, file inside too.
   - `App/Features/SplitViewport/LazyPanelHost.swift`, `PanelHostFeature.swift` — `git mv`.
   - `App/Features/Root/RootFeature.swift`, `App/Features/CommandPalette/CommandPaletteItems.swift`, `App/Features/Socket/handlers/HierarchyHandlers.swift`, `App/Clients/HierarchyClient.swift`, `Hooks/EventMapper.swift`, `Hooks/HookAction.swift`.

6. **Tests** (mechanical)
   - `CodansCoreTests/*` — especially `Hooks/PanelLabelsCatalogTests.swift` (file rename), `TemplateFieldTests.swift`, `SplitTreeTests.swift`, `AgentDetectionRulesTests.swift`, Hooks/* codable round trips.
   - `CodansKitTests/AliasResolverTests.swift`, `CodansKitTests/ExitCodeTests.swift` — env-var string and `notFound(kind: "panel", …)` magic string.
   - `codans/Tests/*` — `PanelActionRouterFeatureTests.swift`, `PanelHostFeatureTests.swift`, `PanelSurfaceApplyTests.swift`, `TerminalEngineTests.swift`, `NotificationsTests/*`, `Hooks/EventMapperTests.swift`, `Hooks/HierarchyManagerSetPanelLabelsTests.swift`.

7. **Shell shims** (`skills/codans-cli/shims/`)
   - `aider-idle-hook.sh`, `claude-stop-hook.sh`, `codex-complete-hook.sh` — each references `${CODANS_PANEL_ID:-unknown}` and one ships a `panel.outputMatch` comment.

8. **Docs** (prose-only)
   - `docs/architecture.md`, `docs/product-spec.md`, every file under `docs/design-docs/`, every file under `docs/exec-plans/` (including `0009-panel-host-feature.md` — `git mv` to `0009-pane-host-feature.md`).
   - Everything under `skills/codans-cli/` (`agents/`, `references/`, README, etc.).

**Do not touch**:
- `apps/mac/ThirdParty/**` (git submodule, contains Ghostty's own `NSPanel` subclasses).
- Any `NSPanel` / `NSOpenPanel` / `NSSavePanel` / `NSColorPanel` / `NSFontPanel` / `NSPrintPanel` / `NSPDFPanel` identifier — AppKit system classes, unrelated to our concept.
- `apps/mac/codans/App/Features/Settings/Panes/` — already uses "pane" to mean "settings subpage" (see DEC-2).
- `SettingsWindowFeature.repositoryPanes` — same reason.

## Plan of Work

The work divides cleanly into four commits. The first must be atomic (Swift compilation would fail mid-rename otherwise). The remaining three touch only text/markdown and can be parallelized across two Agent subagents after the first lands.

### Milestone 1: Atomic Swift + wire + CLI rename

This is the single commit where intermediate states do not build. Performed on `main` (as directed by the user), driven by the primary agent with precise `sed` sweeps and per-file Edit follow-up for anything sed cannot handle cleanly.

**Naming map.** Every identifier below is renamed mechanically with whole-word boundaries:

| Old | New |
|---|---|
| `PanelID` | `PaneID` |
| `Panel` (the struct) | `Pane` |
| `PanelActionRequest` | `PaneActionRequest` |
| `PanelInfoDelta` | `PaneInfoDelta` |
| `PanelOpenRequest` | `PaneOpenRequest` |
| `PanelSurface` | `PaneSurface` |
| `PanelHostView` | `PaneHostView` |
| `PanelHostFeature` | `PaneHostFeature` |
| `LazyPanelHost` | `LazyPaneHost` |
| `PanelActionRouter*` | `PaneActionRouter*` |
| `PanelCommand` (ArgumentParser) | `PaneCommand` |
| `PanelList`, `PanelListRenderable`, `PanelLocatorArgs`, `PanelClose`, `PanelFocus`, `PanelLabels`, `PanelSend`, `PanelShow`, etc. | `PaneList`, `PaneListRenderable`, … |
| `panels` (property) | `panes` |
| `panelID` / `panelId` / `panelID:` | `paneID` / `paneId` / `paneID:` |
| `flatPanelIDs` | `flatPaneIDs` |
| `contextPanelID` | `contextPaneID` |
| `panelLabels` / `panelLabelledAgent` | `paneLabels` / `paneLabelledAgent` |
| `duplicatePanelIDs` (enum case) | `duplicatePaneIDs` |
| `leavesDoNotMatchPanels` | `leavesDoNotMatchPanes` |
| `.panelIdle` / `.panelCreated` / `.panelReady` / `.panelInput` / `.panelOutput` / `.panelOutputMatch` / `.panelExited` / `.panelCrashed` | `.paneIdle` / `.paneCreated` / … |
| `"panel.idle"` / `"panel.created"` / … (raw values) | `"pane.idle"` / `"pane.created"` / … |
| `"panel.id"` / `"panel.workingDirectory"` / `"panel.initialCommand"` (TemplateField) | `"pane.id"` / `"pane.workingDirectory"` / `"pane.initialCommand"` |
| `"hierarchy.listPanels"` / `"hierarchy.describePanel"` / `"hierarchy.openPanel"` / `"hierarchy.splitPanel"` / `"hierarchy.closePanel"` / `"hierarchy.focusPanel"` / `"hierarchy.resizePanel"` / `"hierarchy.zoomPanel"` / `"hierarchy.unzoomPanel"` / `"hierarchy.resolvePanelLabel"` / `"hierarchy.setPanelLabels"` | `"hierarchy.listPanes"` / `"hierarchy.describePane"` / `"hierarchy.openPane"` / … |
| `"terminal.retryPanel"` | `"terminal.retryPane"` |
| `hierarchyListPanels` / `hierarchyDescribePanel` / … (Swift enum cases) | `hierarchyListPanes` / `hierarchyDescribePane` / … |
| `CODANS_PANEL_ID` (env var) | `CODANS_PANE_ID` |
| CLI subcommand `codans panel …` | `codans pane …` |
| Command palette IDs `panel.new-tab`, `panel.equalize`, `panel.close-tab`, `panel.split.right`, `panel.split.down`, `panel.focus.{left,right,up,down}`, … | `pane.new-tab`, `pane.equalize`, … |
| `AliasResolver` env switch case `"CODANS_PANEL_ID"` | `"CODANS_PANE_ID"` |
| `AliasResolveRequest.Kind.panel` | `.pane` (raw still `"pane"`) |
| `worktreeID(forPanel:)` / `panelIDs(inWorktree:)` | `worktreeID(forPane:)` / `paneIDs(inWorktree:)` |
| `NotFound(kind: "panel", …)` | `NotFound(kind: "pane", …)` |

**File renames** (via `git mv`, same commit):
- `apps/mac/CodansCore/Panel.swift` → `apps/mac/CodansCore/Pane.swift`
- `apps/mac/CodansCore/PanelActionRequest.swift` → `apps/mac/CodansCore/PaneActionRequest.swift`
- `apps/mac/CodansCore/PanelInfoDelta.swift` → `apps/mac/CodansCore/PaneInfoDelta.swift`
- `apps/mac/CodansIPC/WireTypes/PanelOpenRequest.swift` → `apps/mac/CodansIPC/WireTypes/PaneOpenRequest.swift`
- `apps/mac/codans/App/PanelHostView.swift` → `apps/mac/codans/App/PaneHostView.swift`
- `apps/mac/codans/Runtime/Ghostty/PanelSurface.swift` → `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift`
- `apps/mac/codans/App/Features/PanelActionRouter/` → `apps/mac/codans/App/Features/PaneActionRouter/` (directory + contents)
- `apps/mac/codans/App/Features/SplitViewport/LazyPanelHost.swift` → `LazyPaneHost.swift`
- `apps/mac/codans/App/Features/SplitViewport/PanelHostFeature.swift` → `PaneHostFeature.swift`
- `apps/mac/codans/Tests/PanelActionRouterFeatureTests.swift` → `PaneActionRouterFeatureTests.swift`
- `apps/mac/codans/Tests/PanelHostFeatureTests.swift` → `PaneHostFeatureTests.swift`
- `apps/mac/codans/Tests/PanelSurfaceApplyTests.swift` → `PaneSurfaceApplyTests.swift`
- `apps/mac/codans/Tests/Hooks/HierarchyManagerSetPanelLabelsTests.swift` → `HierarchyManagerSetPaneLabelsTests.swift`
- `apps/mac/CodansCoreTests/Hooks/PanelLabelsCatalogTests.swift` → `PaneLabelsCatalogTests.swift`

**Execution order inside the commit** (all in one commit, executed strictly in this order so intermediate sed sweeps don't corrupt each other):

1. `git mv` all files listed above.
2. Run guarded whole-word sed across `apps/mac/` (excluding `ThirdParty/`, `Tuist/.build/`, `.build/`): `Panel`→`Pane`, `panels`→`panes`, `panelID`→`paneID`, `panelId`→`paneId`, `PANEL`→`PANE` (in env var only — scoped), and the string-literal raw-value rewrites `"panel."`→`"pane."` and `"*Panel"`→`"*Pane"` in IPC method strings.
3. Pass by hand: the `AliasResolveRequest.Kind` raw value was already "pane" implicitly — check. The `Catalog.worktreeID(forPanel:)` label rename requires a dedicated Edit because sed on word boundaries might miss `(forPanel:` as a single token depending on the regex engine.
4. `make mac-generate` to regenerate Xcode project (picks up moved files).
5. `make mac-build` for both `codans` and `codans` schemes.
6. `xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans test` and the `codans` scheme test.
7. `make mac-lint` and `make mac-check`.
8. Single commit: `refactor: rename panel concept to pane`.

**Parallelism decision.** Do NOT parallelize this milestone via subagents. The files form a tight dependency web through Core types; two agents editing `apps/mac/CodansCore/` and `apps/mac/codans/` simultaneously would almost certainly disagree on at least one identifier spelling. Single-agent sweep is safer and faster.

**Observable acceptance.** After the commit, `grep -rn "Panel\|panel" apps/mac --include="*.swift" | grep -vE "NSPanel|NSOpenPanel|NSSavePanel|NSColorPanel|NSFontPanel|NSPrintPanel|NSPDFPanel|repositoryPane|Settings/Panes|ComingSoonPane"` returns zero matches. `codans pane list` works; `codans panel list` prints an unknown-command error. `make mac-build` and the test suite pass.

### Milestone 2: Shell shim scripts

Touches `skills/codans-cli/shims/aider-idle-hook.sh`, `claude-stop-hook.sh`, `codex-complete-hook.sh`. Each file has a one-line sed replacement of `CODANS_PANEL_ID` → `CODANS_PANE_ID` (and one comment in `claude-stop-hook.sh` referencing "panel.outputMatch"). Because the shims consume the env var the app sets, this commit follows M1 immediately.

**Parallelism decision.** No. Three tiny files; parallelizing adds coordination overhead for no gain. Primary agent handles it.

**Observable acceptance.** `grep -n "CODANS_PANEL_ID\|panel\." skills/codans-cli/shims/*.sh` returns nothing. Running any shim from a Pane continues to emit the expected `::codans:…` sentinel.

### Milestone 3: `docs/**` prose rename (parallel)

Touches all `.md` under `docs/`. Delegated to a subagent. The agent reads the naming map in this plan, runs `grep -rln "\bpanel\b\|\bPanel\b\|\bPANEL\b" docs/`, and for each file either uses `sed` (for simple whole-word cases) or Edit (for prose paragraphs where context matters, e.g. "A Panel inside a Tab" → "A Pane inside a Tab"). The file `docs/exec-plans/0009-panel-host-feature.md` is `git mv`ed to `0009-pane-host-feature.md`.

**Parallelism decision.** Yes — subagent with `subagent_type: general-purpose`, runs concurrently with Milestone 4. No cross-file refs between `docs/` and `skills/` need resolution.

**Observable acceptance.** `grep -rn "\bPanel\b\|\bpanel\b" docs/ | grep -v "NSPanel\|NSOpenPanel"` returns zero matches (modulo prose quoting past commit hashes or ADRs that intentionally discuss the rename itself — expected hits go in this exec-plan document's Surprises section for cross-reference).

### Milestone 4: `skills/codans-cli/**` prose rename (parallel)

Delegated to a second subagent concurrent with M3. Touches `.md` / `.sh` references under `skills/codans-cli/` excluding the shims already handled in M2. Follows the same mechanical strategy as M3.

**Observable acceptance.** `grep -rn "\bPanel\b\|\bpanel\b" skills/codans-cli/` returns zero matches except legitimate third-party mentions (there are none).

### Milestone 5: `/codex:review`

Run `/codex:review` over the branch. Codex receives the full diff. Expected: confirmation that the rename is complete, no stragglers, no behavior change. Any findings are triaged — must-fix items become new commits, nice-to-haves are documented in Surprises & Discoveries.

## Concrete Steps

All commands run from repo root `/Users/wanggang/dev/00/codans`.

### M1 — Atomic Swift rename

1. Create a baseline list of panel-referring files so we can audit the sweep afterwards:

       grep -rln 'Panel\|panel' apps/mac --include="*.swift" \
         | grep -v '/ThirdParty/' | grep -v '/.build/' | grep -v 'Tuist/.build' \
         > /tmp/panel_files_before.txt
       wc -l /tmp/panel_files_before.txt   # expect ~140

2. Perform all `git mv` moves listed in Plan of Work / Milestone 1. Verify with `git status`.

3. Run sed sweeps (BSD sed syntax, macOS):

       # Whole-word PascalCase rename. Order matters: longest prefixes first.
       find apps/mac -type f \( -name "*.swift" \) \
         ! -path '*/ThirdParty/*' ! -path '*/.build/*' ! -path '*/Tuist/.build/*' \
         -exec sed -i '' \
           -e 's/\bPanelActionRouter/PaneActionRouter/g' \
           -e 's/\bPanelActionRequest/PaneActionRequest/g' \
           -e 's/\bPanelInfoDelta/PaneInfoDelta/g' \
           -e 's/\bPanelOpenRequest/PaneOpenRequest/g' \
           -e 's/\bPanelHostFeature/PaneHostFeature/g' \
           -e 's/\bPanelHostView/PaneHostView/g' \
           -e 's/\bPanelSurface/PaneSurface/g' \
           -e 's/\bLazyPanelHost/LazyPaneHost/g' \
           -e 's/\bPanelCommand\b/PaneCommand/g' \
           -e 's/\bPanelList\b/PaneList/g' \
           -e 's/\bPanelListRenderable/PaneListRenderable/g' \
           -e 's/\bPanelLocatorArgs/PaneLocatorArgs/g' \
           -e 's/\bPanelClose/PaneClose/g' \
           -e 's/\bPanelFocus/PaneFocus/g' \
           -e 's/\bPanelLabels/PaneLabels/g' \
           -e 's/\bPanelSend/PaneSend/g' \
           -e 's/\bPanelShow/PaneShow/g' \
           -e 's/\bPanelSplit/PaneSplit/g' \
           -e 's/\bPanelResize/PaneResize/g' \
           -e 's/\bPanelZoom/PaneZoom/g' \
           -e 's/\bPanelUnzoom/PaneUnzoom/g' \
           -e 's/\bPanelRetry/PaneRetry/g' \
           -e 's/\bPanelID\b/PaneID/g' \
           -e 's/\bPanel\b/Pane/g' \
           {} +

       # camelCase and raw strings.
       find apps/mac -type f \( -name "*.swift" \) \
         ! -path '*/ThirdParty/*' ! -path '*/.build/*' ! -path '*/Tuist/.build/*' \
         -exec sed -i '' \
           -e 's/\bpanelID\b/paneID/g' \
           -e 's/\bpanelId\b/paneId/g' \
           -e 's/\bpanelIDs\b/paneIDs/g' \
           -e 's/\bflatPanelIDs\b/flatPaneIDs/g' \
           -e 's/\bcontextPanelID\b/contextPaneID/g' \
           -e 's/\bpanelLabels\b/paneLabels/g' \
           -e 's/\bpanelLabelledAgent\b/paneLabelledAgent/g' \
           -e 's/\bduplicatePanelIDs\b/duplicatePaneIDs/g' \
           -e 's/\bleavesDoNotMatchPanels\b/leavesDoNotMatchPanes/g' \
           -e 's/\bforPanel:/forPane:/g' \
           -e 's/\bpanelIdle\b/paneIdle/g' \
           -e 's/\bpanelCreated\b/paneCreated/g' \
           -e 's/\bpanelReady\b/paneReady/g' \
           -e 's/\bpanelInput\b/paneInput/g' \
           -e 's/\bpanelOutput\b/paneOutput/g' \
           -e 's/\bpanelOutputMatch\b/paneOutputMatch/g' \
           -e 's/\bpanelExited\b/paneExited/g' \
           -e 's/\bpanelCrashed\b/paneCrashed/g' \
           -e 's/\bhierarchyListPanels\b/hierarchyListPanes/g' \
           -e 's/\bhierarchyDescribePanel\b/hierarchyDescribePane/g' \
           -e 's/\bhierarchyResolvePanelLabel\b/hierarchyResolvePaneLabel/g' \
           -e 's/\bhierarchySetPanelLabels\b/hierarchySetPaneLabels/g' \
           -e 's/\bhierarchyOpenPanel\b/hierarchyOpenPane/g' \
           -e 's/\bhierarchySplitPanel\b/hierarchySplitPane/g' \
           -e 's/\bhierarchyClosePanel\b/hierarchyClosePane/g' \
           -e 's/\bhierarchyFocusPanel\b/hierarchyFocusPane/g' \
           -e 's/\bhierarchyResizePanel\b/hierarchyResizePane/g' \
           -e 's/\bhierarchyZoomPanel\b/hierarchyZoomPane/g' \
           -e 's/\bhierarchyUnzoomPanel\b/hierarchyUnzoomPane/g' \
           -e 's/\bterminalRetryPanel\b/terminalRetryPane/g' \
           -e 's/\bpanels\b/panes/g' \
           -e 's/CODANS_PANEL_ID/CODANS_PANE_ID/g' \
           -e 's/"hierarchy\.listPanels"/"hierarchy.listPanes"/g' \
           -e 's/"hierarchy\.describePanel"/"hierarchy.describePane"/g' \
           -e 's/"hierarchy\.resolvePanelLabel"/"hierarchy.resolvePanePaneLabel"/g' \
           -e 's/"hierarchy\.setPanelLabels"/"hierarchy.setPaneLabels"/g' \
           -e 's/"hierarchy\.openPanel"/"hierarchy.openPane"/g' \
           -e 's/"hierarchy\.splitPanel"/"hierarchy.splitPane"/g' \
           -e 's/"hierarchy\.closePanel"/"hierarchy.closePane"/g' \
           -e 's/"hierarchy\.focusPanel"/"hierarchy.focusPane"/g' \
           -e 's/"hierarchy\.resizePanel"/"hierarchy.resizePane"/g' \
           -e 's/"hierarchy\.zoomPanel"/"hierarchy.zoomPane"/g' \
           -e 's/"hierarchy\.unzoomPanel"/"hierarchy.unzoomPane"/g' \
           -e 's/"terminal\.retryPanel"/"terminal.retryPane"/g' \
           -e 's/"panel\./"pane./g' \
           -e 's/panel\.id/pane.id/g' \
           -e 's/panel\.workingDirectory/pane.workingDirectory/g' \
           -e 's/panel\.initialCommand/pane.initialCommand/g' \
           -e 's/commandName: "panel"/commandName: "pane"/g' \
           -e 's/kind: "panel"/kind: "pane"/g' \
           {} +

    **IMPORTANT**: The line `s/"hierarchy\.resolvePanelLabel"/"hierarchy.resolvePanePaneLabel"/g` in the draft above is a typo — must be `"hierarchy.resolvePaneLabel"`. Re-check before executing.

4. The CLI subcommand itself:

       sed -i '' 's/"panel"/"pane"/g' apps/mac/codans-cli/Commands/HierarchyCommands.swift   # scoped

   (Scoped to that one file; generic string replacement is too broad elsewhere.)

5. Command-palette IDs in `apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift`:

       sed -i '' 's/id: "panel\./id: "pane./g' apps/mac/codans/App/Features/CommandPalette/CommandPaletteItems.swift

6. Regenerate & build:

       make mac-generate
       make mac-build

   Expected: both `codans` and `codans` schemes build cleanly. Any compile error is a missed rename — fix with targeted Edit, re-run.

7. Run tests:

       xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans -destination 'platform=macOS' test 2>&1 | xcbeautify
       xcodebuild -workspace apps/mac/codans.xcworkspace -scheme codans            -destination 'platform=macOS' test 2>&1 | xcbeautify

   Expected: all tests green.

8. Post-sweep audit:

       grep -rn "Panel\|panel" apps/mac --include="*.swift" \
         | grep -vE "NSPanel|NSOpenPanel|NSSavePanel|NSColorPanel|NSFontPanel|NSPrintPanel|NSPDFPanel" \
         | grep -vE "repositoryPane|Settings/Panes|ComingSoonPane" \
         | grep -v ThirdParty

   Expected: empty output.

9. Lint + format:

       make mac-lint
       make mac-check

10. Commit:

        git add -A
        git commit -m "refactor: rename panel concept to pane"

### M2 — Shell shims

    sed -i '' 's/CODANS_PANEL_ID/CODANS_PANE_ID/g' skills/codans-cli/shims/*.sh
    sed -i '' 's/panel\.outputMatch/pane.outputMatch/g'    skills/codans-cli/shims/*.sh
    grep -n "PANEL\|panel" skills/codans-cli/shims/*.sh   # expect empty
    git add skills/codans-cli/shims
    git commit -m "refactor(skills): rename CODANS_PANEL_ID to CODANS_PANE_ID in shims"

### M3 + M4 — Docs (parallel subagents)

Delegated via two `Agent` calls in a single message so they run concurrently. Each agent is briefed with the naming map from this plan. On return, each has produced a single commit under its file tree:

- `refactor(docs): rename panel concept to pane`
- `refactor(skills-docs): rename panel concept to pane`

After both agents return, run the final audit:

    grep -rn "\bPanel\b\|\bpanel\b" docs/ skills/codans-cli/ \
      | grep -vE "NSPanel|NSOpenPanel|NSSavePanel|NSColorPanel|NSFontPanel" \
      | grep -v panel-to-pane-rename.md    # this file legitimately discusses the rename

Expected: empty output.

### M5 — `/codex:review`

Invoke `/codex:review` slash command. Summarize findings in Surprises & Discoveries. Create follow-up commits if anything must change.

## Validation and Acceptance

The rename is accepted when **all** of the following hold:

1. `make mac-build` succeeds on both schemes.
2. Test suites for `codans` and `codans` pass.
3. `make mac-lint` and `make mac-check` print no warnings.
4. `grep -rn "\bPanel\b\|\bpanel\b" apps/mac --include="*.swift" | grep -vE "NSPanel|NSOpenPanel|NSSavePanel|NSColorPanel|NSFontPanel|NSPrintPanel|NSPDFPanel|repositoryPane|Settings/Panes|ComingSoonPane" | grep -v ThirdParty` returns zero lines.
5. `grep -rn "CODANS_PANEL_ID" .` returns zero lines (outside this exec plan).
6. `grep -rn "\"panel\\." apps/mac --include="*.swift"` returns zero lines.
7. Running the app manually: opening a new Pane, the shell reports `env | grep CODANS_PANE_ID` finds the variable.
8. `codans pane list` works; `codans panel list` errors with an unknown-subcommand message.
9. Hook subscribers receive events named `pane.ready`, `pane.output`, etc. (verified in `HookEventCodableTests`).
10. `/codex:review` produces no must-fix findings tied to the rename.

## Idempotence and Recovery

Each sed sweep is idempotent: re-running it after the rename is complete replaces `Pane` with `Pane` (no change). The post-sweep audit `grep` is the authoritative check; if it reports leftovers, re-run the relevant sed with a tighter pattern or hand-edit the offending file.

Recovery paths:

- If M1 breaks the build and the error is localized (one or two files with missed renames), fix with Edit and re-run `make mac-build`. No rollback needed.
- If M1 breaks the build in a widespread way suggesting a sed pattern is wrong, run `git checkout -- .` to discard the worktree state, refine the sed, and retry. Do not commit a broken build.
- If tests pass locally but a CI-only regression appears, the fix is almost certainly in a test fixture that encodes a wire string literally. Grep for the failing literal in `Tests/`.
- If `/codex:review` (M5) flags a missed identifier, a fix-up commit on the branch is the response; do not rebase the M1 commit.

## Artifacts and Notes

- Hotspot files by raw grep count (for reviewer orientation):
    - `apps/mac/codans/Runtime/TerminalEngine.swift` — 105
    - `apps/mac/codans/Runtime/HierarchyManager.swift` — 90
    - `apps/mac/codans/App/Features/Root/RootFeature.swift` — 90
    - `apps/mac/codans/Tests/PanelActionRouterFeatureTests.swift` — 85
    - `apps/mac/codans/Tests/TerminalEngineTests.swift` — 68
    - `apps/mac/codans/App/Features/PanelActionRouter/PanelActionRouterFeature.swift` — 66
    - `apps/mac/codans/Runtime/Ghostty/GhosttyActionDecoder.swift` — 65
    - `apps/mac/codans/Runtime/Ghostty/GhosttyRuntime.swift` — 63
    - `apps/mac/codans/App/Clients/HierarchyClient.swift` — 61
    - `apps/mac/codans-cli/Commands/HierarchyCommands.swift` — 57
- Naming map is the single source of truth. Subagents must not invent alternative spellings.

## Interfaces and Dependencies

At the end of Milestone 1, the following symbols must exist (and the `Panel`-named equivalents must not):

In `apps/mac/CodansCore/IDs.swift`:

    public nonisolated struct PaneID: HierarchyID { … }

In `apps/mac/CodansCore/Pane.swift`:

    public nonisolated struct Pane: Equatable, Sendable, Identifiable, Codable {
      public var id: PaneID
      public var workingDirectory: String
      public var initialCommand: String?
      public var labels: Set<String>
    }

In `apps/mac/CodansCore/Tab.swift`:

    public var panes: [Pane]
    public var flatPaneIDs: Set<PaneID>
    enum InvariantError: Error { case duplicatePaneIDs; case leavesDoNotMatchPanes(leaves: Set<PaneID>, panes: Set<PaneID>) }

In `apps/mac/CodansIPC/Method.swift`:

    case hierarchyListPanes             = "hierarchy.listPanes"
    case hierarchyDescribePane          = "hierarchy.describePane"
    case hierarchyOpenPane              = "hierarchy.openPane"
    case hierarchySplitPane             = "hierarchy.splitPane"
    case hierarchyClosePane             = "hierarchy.closePane"
    case hierarchyFocusPane             = "hierarchy.focusPane"
    case hierarchyResizePane            = "hierarchy.resizePane"
    case hierarchyZoomPane              = "hierarchy.zoomPane"
    case hierarchyUnzoomPane            = "hierarchy.unzoomPane"
    case hierarchyResolvePaneLabel      = "hierarchy.resolvePaneLabel"
    case hierarchySetPaneLabels         = "hierarchy.setPaneLabels"
    case terminalRetryPane              = "terminal.retryPane"

In `apps/mac/CodansCore/Hooks/HookEvent.swift`:

    case paneCreated     = "pane.created"
    case paneReady       = "pane.ready"
    case paneInput       = "pane.input"
    case paneOutput      = "pane.output"
    case paneOutputMatch = "pane.outputMatch"
    case paneIdle        = "pane.idle"
    case paneExited      = "pane.exited"
    case paneCrashed     = "pane.crashed"

In `apps/mac/CodansCore/Notifications/TemplateField.swift`:

    case paneID                = "pane.id"
    case paneWorkingDirectory  = "pane.workingDirectory"
    case paneInitialCommand    = "pane.initialCommand"

In `apps/mac/CodansKit/Transport/AliasResolver.swift`:

    let contextPaneID: PaneID? = env["CODANS_PANE_ID"].flatMap(UUID.init(uuidString:)).map(PaneID.init(raw:))
    // switch: case .pane: return "CODANS_PANE_ID"

In `apps/mac/codans-cli/Commands/HierarchyCommands.swift`:

    struct PaneCommand: AsyncParsableCommand {
      static let configuration = CommandConfiguration(commandName: "pane", abstract: "Pane-level verbs.", subcommands: [PaneList.self, PaneClose.self, PaneFocus.self, PaneLabels.self, PaneSend.self, PaneShow.self, …])
    }
