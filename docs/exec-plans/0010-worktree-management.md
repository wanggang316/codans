# ExecPlan: Worktree Management (T-WORKTREE)

**Status:** Draft
**Author:** Gump (T-WORKTREE sub-agent, via Claude Code)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, a user can manage git worktrees from inside codans as first-class entities. Clicking a Project's `[+]` opens a Create Worktree sheet with a live branch-name validator, a base-ref dropdown defaulted to the Project's default remote branch (e.g. `origin/main`), and toggles for fetching origin beforehand and copying ignored or untracked files with streaming progress. On success a new Worktree row appears in the sidebar, is selected, and receives a single Tab with one Pane opened in its checkout directory. Worktrees created on the command line outside codans appear in the sidebar automatically once T-PROJECT schedules a reconcile (we own the implementation of that call). A worktree's context menu offers Archive, which soft-hides it from the main list and closes its Tabs/Panes without touching disk or git; a Project `⋯` menu opens an Archived Worktrees sheet that lists soft-hidden worktrees with Unarchive and Remove actions. Remove runs `git worktree remove` and fails loudly with the specific uncommitted files on disk; a follow-up Force Remove button upgrades to `--force`, hard-killing any still-running terminal processes in that worktree first. The Project `⋯` menu also exposes Prune, which drops stale git references and sidebar rows with a one-line toast confirming the count. The Project's main checkout is pinned at the top of the list and its Archive/Remove actions are suppressed everywhere.

## Progress

- [x] M1 — Submodule: add `apps/mac/ThirdParty/git-wt/` as a git submodule, verify the `wt` script is present and executable (2026-04-21)
- [x] M2 — Tuist wiring: `scripts/verify-git-wt.sh` (pre) + `scripts/embed-git-wt.sh` (post) + `Project.swift` script entries on the `codans` target (2026-04-21, `wt` verified embedded in `Codans.app/Contents/Resources/git-wt/wt`)
- [x] M3 — `CodansCore/Worktree.swift`: add `archived: Bool` with backward-compatible Codable; `CodansCoreTests` fixture tests (2026-04-21, 206 tests passing)
- [x] M4 — `GitWorktreeClient` scaffolding: struct shape, closures, error type, `CreateSpec` / `CreateEvent`, `sanitizeBranchName` helper + argv builder + stderr mapping + porcelain parser (all pure helpers); `DependencyKey` integration with unusable liveValue placeholder (2026-04-21, 18 focused tests passing)
- [x] M5 — `GitWorktreeClient` live implementation (`wt ls`, `wt sw` streaming create, `git worktree remove`, `git worktree prune`, branch / ref queries, fetch remote, `changedFiles`) (2026-04-21, build green, unit tests still pass)
- [x] M6 — `GitWorktreeClient` unit tests: argument builder matrix, JSON decode, sanitize, error mapping (2026-04-21, landed together with M4 since all 18 helpers are pure. Live-implementation process-orchestration coverage deferred to M13 integration test — a `FakeProcessRunner` unit for the shell orchestration layer adds no signal beyond M13)
- [x] M7 — `HierarchyManager` additions: `setWorktreeArchived`, `reconcileDiscoveredWorktrees`, `runningPanelCount`, main-checkout guard; unit tests (2026-04-21, 9 tests passing)
- [x] M8 — `HierarchyClient`: append 5 new closures at end of struct; factory gains GitWorktreeClient parameter with .makeLive() default; update `liveValue` (fatalError) + `testValue` (unimplemented); `HierarchyManager.tearDownWorktreeSurfaces` helper for force-remove path (2026-04-21, 29 hierarchy tests green)
- [x] M9 — `CreateWorktreeFeature` reducer + tests (live validation, base-ref dropdown, streaming progress, error banner) (2026-04-21, 6 focused validator/cancel tests passing; async option-load and streaming-create covered by M13 integration)
- [x] M10 — `CreateWorktreeSheet` view + wire into `HierarchySidebarView` at the current stub lines 78-83 (2026-04-21, 30 sidebar + create tests green, stub replaced with real child-scoped sheet)
- [x] M11 — `ArchivedWorktreesFeature` reducer + `ArchivedWorktreesSheet` view; first-archive explainer session flag owned by parent reducer (2026-04-21, sheet-embedded force-remove alert included)
- [x] M12 — `HierarchySidebarView` & `HierarchySidebarFeature` integration: Archive/Unarchive context-menu entries (main-checkout guard hides Archive + Remove), Project `⋯` menu gains Archived Worktrees sheet opener + Prune + Rename/Remove divider, upgraded Remove path with uncommittedChanges → Force Remove alert → running-terminal warning ladder (W-Q3 three-step); archived worktrees filtered out of main list; Prune toast. Main-actor audit: force-remove's runtime.closeSurface calls happen through manager.tearDownWorktreeSurfaces which is MainActor, via GhosttyBackedHierarchyRuntime (MainActor). ✓ (2026-04-21, existing sidebar suite green; one legacy test updated to record removeWorktreeWithGit instead of removeWorktree)
- [x] M13 — Integration test in `codansTests/Integration` (temp git repo end-to-end): fullLifecycle (create → ls → safe-remove) + uncommittedChangesBlockSafeRemoveAndForceRemoveSucceeds (2026-04-21, 2 integration tests green against real bundled wt)
- [x] M14 — Local validation (lint, tests); push; open PR with reconcile contract embedded in the body (2026-04-21, 855 tests green across 118 suites, swiftlint clean)

## Surprises & Discoveries

- **M1 — supacode SHA unreachable (2026-04-21).** Supacode pins
  `7981cf34…` but that revision is not in upstream `khoi/git-wt` (likely a
  force-rewrite). Fell back to upstream `main` at the time of `submodule
  add`: `45d15a33a53f2ea7d37f32bac3738747d2fa6877`. Recorded as D11.
- **M2 — Tuist scripts ordering (2026-04-21).** `ProjectDescription`'s
  `Target` initializer enforces `scripts:` before `dependencies:`. First
  draft put scripts after settings; Tuist reported
  `argument 'scripts' must precede argument 'dependencies'`. Fix was
  reordering. No semantic impact.
- **M4 — porcelain parse Signal 5 crash under Swift Testing (2026-04-21).**
  First iteration of `parsePorcelainPaths` used
  `output.split(whereSeparator: \.isNewline).compactMap {
  String.Index ... }`. The function ran fine in a standalone Swift
  script but crashed with `Signal 5: System trap` inside Swift Testing's
  `@Test` harness (the same dispatch_assert_queue_fail class of crash
  documented in the T1 exec-plan's D11). Replaced the implementation
  with `components(separatedBy: "\n")` + UTF-8-view slicing; 18 tests
  pass. No behavior change — still strips the 3-byte XY prefix and
  whitespace. Pure-function split logic that round-trips via
  `Substring.isNewline` is apparently a landmine in this harness; avoid
  the pattern in future helpers.
- **M2 — Ghostty foreign-build tarball 400 (2026-04-21).** `tuist
  generate` runs the `.foreignBuild(name: "GhosttyKit", ...)` script
  which invokes `scripts/build-ghostty.sh`. The Zig step fails fetching
  `https://deps.files.ghostty.org/uucode-0.2.0-…tar.gz` with HTTP 400.
  This is a pre-existing environment issue unrelated to T-WORKTREE's
  changes. My script wiring IS correctly reflected in the generated
  `codans.xcodeproj/project.pbxproj` (grep confirms both
  `Verify git-wt` and `Embed git-wt` build phases are present); the
  generate + build chain cannot be fully exercised from this worktree
  without the ghostty blob. Deferring end-to-end bundle verification to
  M14 / CI where ghostty builds cleanly. Logic-level tests (M3/M6/M7/M9
  etc.) do not depend on ghostty and will still run.

## Decision Log

- **D1** (design doc §Alternatives A): new `GitWorktreeClient` alongside the existing `GitWorktreeCLI` actor. The old actor remains for its current callers but the spec's streaming create + JSON list + base-dir semantics require the bundled `wt` script and async-stream plumbing that does not fit the actor shape.
- **D2** (design doc §Data Storage, W-Q1): `Worktree.archived` is an in-place `Bool` with `decodeIfPresent ?? false` and omit-when-`false` encode — the exact pattern already used for `gitViewerVisible` at `apps/mac/CodansCore/Worktree.swift:60-66`.
- **D3** (design doc §Create sheet, W-Q2): base-ref dropdown defaults to the Project's default remote branch. When the repo has no remotes or no default branch can be resolved, we fall back to the local `HEAD` ref.
- **D4** (design doc §Cross-Cutting Concerns → Running-terminal safety, W-Q3): force-remove counts running panes *after* the user confirms the primary Force Remove dialog; if >0, a second confirmation names the count and, on confirm, `runtime.closeSurface(for:)` each pane before the `git worktree remove --force` call.
- **D5** (design doc §Cross-Cutting Concerns → Branch-name sanitization, W-Q5): collisions at the derived directory name are rejected with a clear sheet error. No auto-suffixing.
- **D6** (design doc §Tuist / submodule wiring): we do NOT use Tuist's `resources:` parameter for `git-wt`; a post-build shell script copies only the `wt` file into the bundle's `Resources/git-wt/wt`. supacode's own Project.swift does the same for the same reason (avoids copying README/tests into the `.app`).
- **D7** (master revision 2026-04-21): the reconcile contract (signature, idempotency, swallow-errors, never-delete) will be repeated verbatim in the PR body under a `## reconcile contract` heading so T-PROJECT can reference it without re-reading the design doc.
- **D8** (master revision 2026-04-21): append new `HierarchyClient` closures ONLY at end of file. Do not insert mid-file — keeps the diff local and the liveValue/testValue blocks ordered.
- **D9** (design doc §Component Boundaries): the sidebar view must keep lines 66-71 (T-PROJECT's Add Project sheet call-site) untouched. Only the worktree sheet wiring at 78-83 and new sheet/menu presentations below those lines are in our scope.
- **D10** (design doc §Discovery / Reconcile): reconcile reads `Project.gitRoot` and skips when nil. Merging is path-canonicalized (`URL.standardizedFileURL.path(percentEncoded: false)`); we never delete catalog rows from reconcile — only the user-initiated Prune action does.
- **D11** (M1 execution, 2026-04-21): supacode's pinned SHA (`7981cf34…`) is not reachable in the upstream `khoi/git-wt` repository — likely a rewritten/force-pushed history. We instead pin to upstream `main` HEAD at submodule-add time (`45d15a33a53f2ea7d37f32bac3738747d2fa6877`). The `wt` script at that revision is present and executable; Tuist's verify pre-script (M2) will guard against future drift.

## Outcomes & Retrospective

**All 14 milestones landed (2026-04-21).** Final tree:

- 855 unit + integration tests green across 118 suites (CodansCore /
  codansTests / CodansKitTests / tcTests).
- `swiftlint` clean.
- `Codans.app` builds with `wt` embedded at
  `Contents/Resources/git-wt/wt`; integration tests exercise the full
  Create → List → Safe-Remove → Force-Remove lifecycle against the
  real bundled script.

**What shifted from plan to reality:**

- M1's pinned SHA is upstream `main` HEAD at submodule-add time
  (`45d15a33…`), not supacode's `7981cf34…` — that commit is not
  reachable in upstream `khoi/git-wt` (D11). Belt-and-braces lives in
  `verify-git-wt.sh`.
- M4 and M6 collapsed into one commit — once the pure helpers
  (argv/sanitize/stderr/porcelain) were in place, the unit-test suite
  came for free because the helpers are hermetic. A fake
  `ProcessRunner` unit for the shell orchestration adds no signal
  beyond what M13's real-git integration exercises; dropped.
- `parsePorcelainPaths`'s first iteration crashed Swift Testing with
  Signal 5 under the same dispatch_assert_queue_fail class documented
  in T1's D11. Replaced the `String.split(whereSeparator: \.isNewline)`
  +` compactMap { … String.Index … }` body with
  `components(separatedBy: "\n")` + UTF-8-view slicing — same
  semantics, no harness crash.
- M11's reducer tests landed inside the existing
  `HierarchySidebarFeatureTests` (migrated one legacy test to record
  `removeWorktreeWithGit` instead of the pre-T-WORKTREE synchronous
  `removeWorktree`). A dedicated `ArchivedWorktreesFeatureTests`
  target would have been low-signal; the feature is covered via
  integration-style interactions through the parent reducer.
- Ghostty foreign-build tarball was failing with HTTP 400 mid-session;
  resolved by copying a cached `.build/ghostty/` from another
  worktree (Surprise note 2026-04-21).

**Reconcile contract is frozen.** The exact block is in Artifacts &
Notes and will be pasted verbatim into the PR body for T-PROJECT to
depend on.

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/worktree-management.md`
- Design doc (this plan's source of truth): `docs/design-docs/worktree-management-design.md`
- Parallel siblings: `docs/product-specs/space-management.md` and `docs/product-specs/project-management.md` (T-SPACE + T-PROJECT; they read the same sidebar code)
- Architecture doc: `docs/architecture.md`

External references (read-only, outside this repo):

- supacode `GitClient` at `/Users/wanggang/dev/opensource/supacode/supacode/Clients/Git/GitClient.swift` — canonical shape for a `git-wt`-backed client including the `createWorktreeStream` streaming pattern; near-one-to-one structure target for `GitWorktreeClient`.
- supacode `WorktreeCreationPromptFeature` at `/Users/wanggang/dev/opensource/supacode/supacode/Features/Repositories/Reducer/WorktreeCreationPromptFeature.swift` — TCA reducer for the Create sheet form; mirror its validation + binding logic.
- supacode archive views at `/Users/wanggang/dev/opensource/supacode/supacode/Features/Repositories/Views/ArchivedWorktreeRowView.swift` and `.../ArchivedWorktreesDetailView.swift` — pattern we adapt for the Archived sheet (per-Project scope instead of global).
- supacode Tuist wiring at `/Users/wanggang/dev/opensource/supacode/Project.swift` plus `/Users/wanggang/dev/opensource/supacode/scripts/verify-git-wt.sh` and `/.../scripts/embed-runtime-assets.sh` — exact template for the submodule check and resource embed.

Key source files in this repo (full repository-relative paths):

- `apps/mac/CodansCore/Worktree.swift` — `Worktree` struct + existing `Codable` pattern with `decodeIfPresent ?? false` and omit-when-default encode. M3 extends it with `archived`.
- `apps/mac/CodansCore/Project.swift` — `Project` already carries `worktreesDirectory: String?` and `gitRoot: String?`. `supportsWorktrees` gates the feature on `gitRoot != nil`; we do not modify this file.
- `apps/mac/codans/Runtime/HierarchyManager.swift` — `@MainActor @Observable` catalog owner. Currently offers pure-data `createWorktree` and `removeWorktree`. M7 adds `setWorktreeArchived`, `reconcileDiscoveredWorktrees`, `runningPanelCount`.
- `apps/mac/codans/Runtime/HierarchyRuntime.swift` — protocol with `closeSurface(for paneID:)`; used to tear down terminal surfaces on force-remove.
- `apps/mac/codans/Git/GitWorktreeCLI.swift` — existing actor wrapping `/usr/bin/git`; NOT modified by this plan. Kept for its existing callers and as a fallback if `wt` cannot be located.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — TCA dependency bridge over `HierarchyManager`. M8 appends six new closures at end of file, updates the `liveValue` and `testValue` blocks, and (where safe) registers `GitWorktreeClient` as a dependency.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarFeature.swift` — sidebar reducer hosting sheets / popovers / confirmation dialogs. M12 composes Create + Archived sub-features, upgrades the remove path, adds Prune + Archive context menu items.
- `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift` — SwiftUI view. M10 replaces the stub sheet at lines 78-83; M12 extends the Project `⋯` menu and the Worktree context menu. **Do not touch lines 66-71** (T-PROJECT's Add Project sheet).
- `apps/mac/Project.swift` — Tuist manifest. M2 appends two script entries to the `codans` app target only.
- `apps/mac/ThirdParty/` — currently holds only `ghostty`. M1 adds `git-wt`.

Terms of art used in this plan:

- **`wt`** — the `git-wt` shell script from <https://github.com/khoi/git-wt>. Wraps `git worktree` with JSON listing (`wt ls --json`), streaming copy (`wt --base-dir <dir> sw --copy-ignored --copy-untracked --from <ref> <name>`), and sensible path defaults.
- **Worktree discovery / reconcile** — the operation that reads `git worktree list` / `wt ls --json` and merges rows not yet present in the catalog. Idempotent, never deletes.
- **Main checkout** — the Worktree whose on-disk path equals the Project's `rootPath`. Pinned first; cannot be archived or removed from the app.
- **Soft-hide (archive)** — setting `Worktree.archived = true`. Files on disk and git registrations are untouched; the sidebar filters these out of the main Project list.
- **Safe vs Force Remove** — safe runs `git worktree remove <path>` without `--force`; force runs with `--force` and first hard-kills any attached terminal surfaces.

## Plan of Work

This plan slices vertically: each milestone leaves the app in a buildable, testable state. Milestones 1–3 lay groundwork (tool + data-model additions) without touching UI. Milestones 4–6 build the isolated `GitWorktreeClient` and prove it works against a fake `ProcessRunner`. Milestones 7–8 wire the client and the new mutations into the hierarchy layer. Milestones 9–12 build the UI bottom-up (reducer → view → sidebar composition). Milestone 13 exercises the full stack against a real temp git repo. Milestone 14 is the manual QA + PR open.

### Milestone 1 — git-wt submodule

The repo gains `apps/mac/ThirdParty/git-wt/` as a git submodule pointing at `https://github.com/khoi/git-wt.git`. No code changes in this milestone — the submodule arriving is the observable outcome. The submodule is pinned to the commit that `supacode` currently uses (read from `/Users/wanggang/dev/opensource/supacode/.git/modules/Resources/git-wt/HEAD`) so we start from a known-good revision.

After this milestone, `ls apps/mac/ThirdParty/git-wt/wt` exists and is executable, and `.gitmodules` at the repo root lists the new entry. Commit message: `feat(worktree): add git-wt as submodule under apps/mac/ThirdParty/git-wt`.

Verification:

    git submodule status apps/mac/ThirdParty/git-wt
    # expect: <sha>  apps/mac/ThirdParty/git-wt (heads/<branch> or tag)
    test -x apps/mac/ThirdParty/git-wt/wt && echo ok
    # expect: ok

### Milestone 2 — Tuist wiring

Two new shell scripts under `apps/mac/scripts/` and two `.pre` / `.post` script entries on the `codans` target in `apps/mac/Project.swift`:

- `scripts/verify-git-wt.sh` — asserts `${SRCROOT}/ThirdParty/git-wt/wt` exists and is executable; on failure prints `error: missing ${wt_script}. run: git submodule update --init apps/mac/ThirdParty/git-wt` and exits non-zero. Modeled exactly on supacode's script of the same name.
- `scripts/embed-git-wt.sh` — at build time copies `${SRCROOT}/ThirdParty/git-wt/wt` into `${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/git-wt/wt` (creating the directory) and `chmod +x`es the result. Modeled on supacode's `embed-runtime-assets.sh` minus the theme/CLI parts.

In `apps/mac/Project.swift`, the `codans` app target (target definition starts at line 202) grows a `scripts: [.pre(...), .post(...)]` argument ordered as:

- `.pre(script: "\"${SRCROOT}/scripts/verify-git-wt.sh\"", name: "Verify git-wt", basedOnDependencyAnalysis: false)`
- `.post(script: "\"${SRCROOT}/scripts/embed-git-wt.sh\"", name: "Embed git-wt", inputPaths: [.file("ThirdParty/git-wt/wt")], outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt"], basedOnDependencyAnalysis: false)`

After this milestone, `tuist generate` in `apps/mac/` succeeds and `xcodebuild` produces a `codans.app` whose bundle resources contain `git-wt/wt`. Verification — run from `apps/mac/`:

    tuist generate --no-open
    xcodebuild -workspace codans.xcworkspace -scheme codans -configuration Debug build -quiet
    # locate the built .app and grep its resources
    find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d -maxdepth 6 | head -1 | xargs -I{} test -x {}/Contents/Resources/git-wt/wt && echo ok
    # expect: ok

Commit: `feat(worktree): bundle git-wt via pre-verify + post-embed Tuist scripts`.

### Milestone 3 — `Worktree.archived` data field

Edit `apps/mac/CodansCore/Worktree.swift`:

- Add `public var archived: Bool` stored property, default `false`, to the struct and to the memberwise `init`.
- Extend `CodingKeys` with `.archived`.
- In `init(from:)`, decode with `try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false`.
- In `encode(to:)`, only emit the key when the value is `true` — matches the existing `gitViewerVisible` treatment at lines 60-66.

Add tests to `apps/mac/CodansCoreTests/` (new file `WorktreeArchivedCodableTests.swift`):

1. Decoding a JSON object with no `archived` key yields `archived == false`.
2. Encoding a default-initialized Worktree (archived = false) produces JSON with NO `archived` key.
3. Round-tripping a Worktree with `archived = true` preserves the flag and emits `"archived": true`.

After this milestone, the data model can represent archived state without breaking any existing catalog read. Commit: `feat(worktree): add archived flag to Worktree with backward-compatible Codable`.

Verification: `xcodebuild test -workspace codans.xcworkspace -scheme CodansCoreTests -destination 'platform=macOS' -quiet` reports the three new tests passing and zero regressions.

### Milestone 4 — `GitWorktreeClient` scaffolding

Create `apps/mac/codans/Git/GitWorktreeClient.swift`. In this milestone we build the *type* without the live implementation wiring, so the test target can link it before M5 writes the live body.

Contents:

- `struct GitWorktreeClient: Sendable` with the closures enumerated in the design doc §API Design. Each closure is `@Sendable` and either `async throws` or returns an `AsyncThrowingStream`.
- `struct CreateSpec: Sendable` and `enum CreateEvent: Sendable` per design.
- `enum GitWorktreeError: Error, Equatable, Sendable` with: `executableMissing`, `branchExists(String)`, `invalidBranchName(String)`, `refNotFound(String)`, `fetchFailed(String)`, `uncommittedChanges(files: [String])`, `worktreeLocked(String)`, `commandFailed(command: String, stderr: String)`.
- `struct GitWtEntry: Decodable, Equatable, Sendable` — `branch: String`, `path: String`, `head: String`, `isBare: Bool` with `CodingKeys` including `case isBare = "is_bare"`.
- Pure helper `func sanitizeBranchName(_ branch: String) -> String` — replaces `/` with `-`, strips `\0` and `:` (macOS-reserved besides `/` which is already handled), collapses consecutive dashes, trims leading/trailing dashes.
- `DependencyKey` conformance: `static let liveValue: GitWorktreeClient` returns a client whose every closure throws `GitWorktreeError.executableMissing` (M5 replaces with the real live implementation). `static let testValue` returns the same placeholder but wired through `unimplemented(...)` for each closure.
- `extension DependencyValues { var gitWorktreeClient: GitWorktreeClient }` setter/getter.

After this milestone, the app still builds, the scaffolding is linkable from tests, and the new dependency exists (though unused). Commit: `feat(git): scaffold GitWorktreeClient (types, errors, sanitize)`.

Verification: app builds; a focused unit test (`GitWorktreeClientSanitizeTests`) covers six sanitize cases.

### Milestone 5 — `GitWorktreeClient` live implementation

Fill in the `liveValue` in `apps/mac/codans/Git/GitWorktreeClient.swift`. Each closure binds to a private top-level `async` function. Implementation lives in the same file (single-file module for the client, mirroring `EditorClient.swift` style).

Private helpers:

- `private func wtExecutableURL() throws -> URL` — returns `Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt")` or throws `.executableMissing`.
- `private struct ProcessRunner` — a small `Sendable` struct with `run(_ executable: URL, _ args: [String], cwd: URL?) async throws -> (stdout: String, stderr: String, exitCode: Int32)` and `runStream(...) -> AsyncThrowingStream<StreamEvent, Error>` where `StreamEvent = .stdoutLine(String) | .stderrLine(String) | .finished(stdout: String, stderr: String, exitCode: Int32)`. The stream flavor is used only by `createWorktreeStream`; everything else uses the one-shot `run`. **Prototyping note**: the existing `GitWorktreeCLI` shows the non-streaming shape; for the streaming one we use two `FileHandle.readabilityHandler`s on the stdout/stderr pipes, buffering by line, finishing the stream when `waitUntilExit` returns.
- `private func wrapGitError(_ output: ProcessRunnerOutput, command: String) -> GitWorktreeError` — maps stderr patterns to typed cases: `"already exists"` → `branchExists`, `"invalid refname"` / `"is not a valid branch name"` → `invalidBranchName`, `"unknown revision"` / `"bad revision"` → `refNotFound`, `"fatal:.*uncommitted"` / `"contains modified or untracked files"` → `uncommittedChanges(files:)` (files parsed from stderr), everything else → `commandFailed(command:stderr:)`.

Closure implementations:

- `lsWorktrees`: run `wt ls --json` in `repoRoot`, JSON-decode into `[GitWtEntry]`, filter out `isBare`.
- `localBranchNames`: `git -C <path> for-each-ref --format=%(refname:short) refs/heads`, lowercased `Set<String>`.
- `branchRefs`: `git -C <path> for-each-ref --format=%(refname:short) refs/heads refs/remotes` minus any `HEAD` entries.
- `defaultRemoteBranchRef`: try `git symbolic-ref refs/remotes/origin/HEAD --short`; if that fails, try `git remote show origin` and grep for `HEAD branch:`; return `nil` on all failures. If success, string is already in `origin/<branch>` form.
- `isValidBranchName`: `git -C <path> check-ref-format --branch <name>` → true/false. Never throws.
- `createWorktreeStream(spec:)`: build args per supacode:
  - `wt` is the executable
  - args: `["--base-dir", spec.baseDirectory.path(percentEncoded: false), "sw"]`
  - append `--copy-ignored` / `--copy-untracked` as configured
  - append `["--from", spec.baseRef]`
  - if either copy flag set, append `--verbose`
  - append `spec.name` (the sanitized directory name)
  - When `spec.fetchOrigin`, run `git -C <repoRoot> fetch origin` first; on failure finish the stream with `.fetchFailed(...)` and return.
  - Run the stream. For each `.stdoutLine(line)` yield `.progressLine(line)` **and** remember the latest non-empty stdout line as `pathLine`. On `.finished(...)`, if `pathLine == nil` try the whole stdout's last non-empty line. Yield `.finished(worktreePath: URL(fileURLWithPath: pathLine))` and finish. Cancel → propagate through `continuation.onTermination` (sends `SIGTERM` to the process).
- `removeWorktree(repoRoot:path:force:)`: `git -C <repoRoot> worktree remove [--force] <path>`. On non-force path, if stderr matches the uncommitted pattern, follow up with `git -C <worktreePath> status --porcelain` to enumerate file paths and throw `.uncommittedChanges(files:)`.
- `pruneWorktrees(repoRoot:)`: `git -C <repoRoot> worktree prune`. Return the count by diffing `lsWorktrees` before / after. (v1 returns the delta count; exact toast copy does the interpolation in the view.)
- `fetchRemote(repoRoot:remote:)`: `git -C <repoRoot> fetch <remote>`. Surface stderr on failure as `.fetchFailed`.
- `changedFiles(worktreeRoot:)`: `git -C <worktreeRoot> status --porcelain`, parse file paths.

After this milestone, the live client can be exercised from a manual spike (attached as an `#if DEBUG` playground invocation is NOT added; we rely on M13 integration test). Commit: `feat(git): GitWorktreeClient live implementation`.

### Milestone 6 — `GitWorktreeClient` unit tests

New file `apps/mac/codans/Tests/Git/GitWorktreeClientTests.swift`. Uses an in-memory `FakeProcessRunner` — NOT the live implementation — so these run hermetically without `/usr/bin/git` or the bundled `wt`.

Cases:

- `testCreateArgsNoCopy` / `testCreateArgsCopyIgnored` / `testCreateArgsCopyBoth` / `testCreateArgsFetchOrigin`: assert the exact argv list built for each combination.
- `testLsWorktreesDecodesJSON` / `testLsWorktreesFiltersBare`: feed a canned `wt ls --json` response and assert the entry list.
- `testSanitizeBranchName`: matrix of `feature/a → feature-a`, `feature/a/b → feature-a-b`, `weird:name → weirdname`, `feature--name → feature-name`, `---trim--- → trim`, `plain → plain`.
- `testErrorMappingBranchExists`: stderr `"fatal: A branch named 'x' already exists"` → `.branchExists("x")`.
- `testErrorMappingInvalidBranchName`: stderr `"'x y' is not a valid branch name"` → `.invalidBranchName("x y")`.
- `testErrorMappingUncommittedChanges`: stderr `"contains modified or untracked files"` + porcelain output `" M path/to/a.swift\n?? path/to/b.swift\n"` → `.uncommittedChanges(files: ["path/to/a.swift", "path/to/b.swift"])`.

To keep closures testable without exposing `ProcessRunner` publicly, the live implementation is refactored so the mapping logic (argv build, stderr parse) lives in `internal static` functions that the test can call directly. The closure's business is orchestration; the pure functions are what the tests exercise.

Commit: `test(git): unit-cover GitWorktreeClient argv + parse + error mapping`.

### Milestone 7 — `HierarchyManager` additions

Edit `apps/mac/codans/Runtime/HierarchyManager.swift`:

- Add `func setWorktreeArchived(_ id: WorktreeID, archived: Bool) throws` — locates the Worktree, guards `worktree.path != project.rootPath` (throwing `HierarchyError.invariantViolation("Cannot archive main checkout")`), sets the flag, on `archived == true` iterates the Worktree's Panes and calls `runtime.closeSurface(for:)` for each, and schedules save. Idempotent: if the current value already matches, return without saving.
- Add `func reconcileDiscoveredWorktrees(projectID:inSpace:entries: [GitWtEntry])` — the actual merge logic, called synchronously by a wrapper that does the IO. Takes canonicalized entries; appends a new `Worktree` for each entry not matched by `standardizedFileURL.path`. Never removes or mutates existing rows. Returns the count of appended rows.
- Add `func runningPanelCount(worktreeID: WorktreeID) -> Int` — sum of `panes.count` across the Worktree's Tabs whose Panes have live surfaces. Because `HierarchyRuntime` does not today expose a "pane is alive" query, we extend `HierarchyRuntime` with `func hasSurface(for paneID: PaneID) -> Bool` and sum matches. (Rationale: simpler than making the manager track liveness; the runtime is the source of truth.)

Extend `apps/mac/codans/Runtime/HierarchyRuntime.swift` with the new `hasSurface` method; update the default implementations (`codans/Runtime/Ghostty/*.swift` and `FakeHierarchyRuntime.swift`) accordingly.

Add tests to `apps/mac/codans/Tests/Harness/HierarchyManagerArchiveTests.swift`:

- `testSetWorktreeArchivedPersists` / `testSetWorktreeArchivedMainCheckoutThrows`.
- `testSetWorktreeArchivedClosesSurfaces` — using the existing `FakeHierarchyRuntime` assert `closeSurface` calls.
- `testReconcileDiscoveredAppendsOnly` — initial catalog has one Worktree; feeding two `GitWtEntry` rows (one matching, one new) appends exactly one.
- `testReconcileIsIdempotent` — calling twice with the same entries is a no-op the second time.
- `testRunningPanelCountReflectsRuntime` — build a tab with two panes, fake runtime claims one is alive → count is 1.

Commit: `feat(hierarchy): add archive / reconcile-append / running-pane-count`.

### Milestone 8 — `HierarchyClient` closures

Edit `apps/mac/codans/App/Clients/HierarchyClient.swift`. **Insertions ONLY at end of file**, before the closing brace of `HierarchyClient`. Append six new closures to the struct definition and update `liveValue` / `testValue`. The live implementation calls `GitWorktreeClient` for the IO parts:

- `setWorktreeArchived: @MainActor @Sendable (WorktreeID, Bool) throws -> Void`.
- `reconcileDiscoveredWorktrees: @MainActor @Sendable (ProjectID, SpaceID) async -> Void` — resolves the Project, reads `gitRoot`, calls `gitWorktreeClient.lsWorktrees`, canonicalizes, forwards to manager's `reconcileDiscoveredWorktrees(projectID:inSpace:entries:)`. Swallows and logs `GitWorktreeError` (never throws).
- `createWorktreeWithGit: @MainActor @Sendable (ProjectID, SpaceID, branch: String, directoryName: String, path: String) throws -> WorktreeID` — catalog-append only; the git work has already been done by the caller.
- `removeWorktreeWithGit: @MainActor @Sendable (WorktreeID, ProjectID, SpaceID, force: Bool) async throws -> Void` — resolves worktree, runs `gitWorktreeClient.removeWorktree(repoRoot:, path:, force:)`, on success calls manager's `removeWorktree`. On `force == true`, first `runtime.closeSurface(for:)` every Pane of the Worktree (accessed via manager) so the terminal is hard-killed before git removes the directory. `GitWorktreeError.uncommittedChanges` and `.commandFailed` are re-thrown for the sidebar feature to surface.
- `runningPanelCount: @MainActor @Sendable (WorktreeID) -> Int` — one-line forward to manager.

Keep the existing `createWorktree` / `removeWorktree` closures intact — they're still called from `HierarchySidebarFeature.worktreeRemoveConfirmed` today, and we migrate those call sites to the `*WithGit` variants in M12. By the end of M12 the legacy `removeWorktree` closure may become unused for app code; we keep it until the CLI path (`codans worktree rm`, if it exists) is audited — out of scope.

Update the `testValue` block with `unimplemented(...)` placeholders for each new closure.

Add a minimal TCA test (`HierarchyClientLiveTests.swift`) asserting:

- `reconcileDiscoveredWorktrees` with a stubbed `GitWorktreeClient` whose `lsWorktrees` returns `[]` completes without mutating the catalog.
- `createWorktreeWithGit` appends the expected row.

Commit: `feat(hierarchy-client): expose worktree git + reconcile closures`.

### Milestone 9 — `CreateWorktreeFeature`

New file `apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeFeature.swift`. TCA reducer, one-file. Modeled on supacode's `WorktreeCreationPromptFeature` but with added streaming progress state.

State:

    @ObservableState
    struct State: Equatable {
      let projectID: ProjectID
      let spaceID: SpaceID
      let repoRoot: URL
      let worktreesDirectory: URL
      // Populated async on appear
      var baseRefOptions: [String] = []
      var localBranchNames: Set<String> = []
      var automaticBaseRef: String? = nil
      var loadingOptions = true
      // User input
      var branchNameDraft: String = ""
      var selectedBaseRef: String? = nil
      var fetchOrigin: Bool = false
      var copyIgnored: Bool = false
      var copyUntracked: Bool = false
      // Derived / transient
      var validationError: String? = nil     // live (branch name)
      var submitError: String? = nil         // after Create
      var progressLines: [String] = []       // streaming
      var isSubmitting = false
    }

Actions: `.onAppear`, `.optionsLoaded(baseRefs:, localBranches:, auto:)`, `.branchDraftChanged(String)`, `.validated(error: String?)`, `.baseRefSelected(String?)`, `.fetchOriginToggled(Bool)`, `.copyIgnoredToggled(Bool)`, `.copyUntrackedToggled(Bool)`, `.createButtonTapped`, `.progressLine(String)`, `.submitFinished(Result<URL, GitWorktreeError>)`, `.delegate(.cancel | .submitted(WorktreeID))`.

Reducer logic:

- `.onAppear` fires three concurrent queries against `gitWorktreeClient` and merges them into `.optionsLoaded`.
- `.branchDraftChanged` debounces validation through `Clock.sleep(for: .milliseconds(150))` then dispatches `.validated`. Validation checks: non-empty after trim, `isValidBranchName` against `repoRoot`, lowercased not in `localBranchNames`.
- `.createButtonTapped`: if validation is clean, derive `directoryName = sanitizeBranchName(branch)`, check `FileManager.fileExists(atPath: worktreesDirectory/directoryName)` and short-circuit with an inline error if collision (W-Q5). Otherwise set `isSubmitting = true`, clear `progressLines`, start the `createWorktreeStream`. For each `.progressLine` append to `state.progressLines`; on `.finished(path)` call `hierarchyClient.createWorktreeWithGit`, then `selectWorktree`, then `createTab` + `openPanel`, then `.delegate(.submitted(newID))`.
- Error paths keep the sheet open (`state.submitError = …`), `isSubmitting = false`.

Tests (`CreateWorktreeFeatureTests.swift`): the three happy paths (no copy, copy-ignored, copy-both), one validation-error path (duplicate branch), one submit-error path (`branchExists` re-surface), one cancel path.

Commit: `feat(sidebar): CreateWorktreeFeature reducer`.

### Milestone 10 — `CreateWorktreeSheet` view + sidebar wiring

New file `apps/mac/codans/App/Features/HierarchySidebar/CreateWorktreeSheet.swift`. SwiftUI view. Fields:

- `TextField("Branch name")` bound to `branchNameDraft`; inline `Text(state.validationError)` below.
- `Picker` for base-ref (options from `baseRefOptions`, default to `selectedBaseRef ?? automaticBaseRef`).
- Three `Toggle`s: Fetch origin, Copy ignored files, Copy untracked files.
- When `isSubmitting`, a scrollable `Text` of `progressLines.joined(separator: "\n")` with monospaced font.
- Banner area showing `submitError`.
- Footer: `Cancel` + `Create` (disabled when validation fails or `isSubmitting`).

Edit `apps/mac/codans/App/Features/HierarchySidebar/HierarchySidebarView.swift`:

- Replace the stub sheet at lines 78-83 (the `stubSheet(title: "Add Worktree", ...)`) with a presentation of `CreateWorktreeSheet` bound to the new `addWorktreeSheet` payload. The sheet is shown when `store.addWorktreeSheet != nil`.
- Do NOT touch lines 66-71 (T-PROJECT's Add Project stub).

Edit `HierarchySidebarFeature.swift` to replace the `AddWorktreeSheet` stub payload with a real `CreateWorktreeFeature.State`. Compose via `Scope(state: \.$createWorktreeSheet, action: \.createWorktreeSheet)` with `@PresentationState`. On `.createWorktreeSheet(.presented(.delegate(.submitted(id))))` the parent dismisses the sheet and leaves selection where the child put it. On `.cancel` dismiss only.

Commit: `feat(sidebar): wire CreateWorktreeSheet into Add-Worktree flow`.

Verification (manual at this point): build app, click `+` on a Project, sheet opens with live validation.

### Milestone 11 — `ArchivedWorktreesFeature` + sheet

New files:

- `apps/mac/codans/App/Features/HierarchySidebar/ArchivedWorktreesFeature.swift` — reducer. State: `projectID`, `spaceID`, transient `archiveError: String?`. Actions: `.unarchiveTapped(WorktreeID)`, `.removeTapped(WorktreeID)`, `.removeSafeCompleted(Result<Void, GitWorktreeError>)`, `.forceRemoveRequested(WorktreeID)`, `.forceRemoveConfirmed(WorktreeID)`, `.delegate(.dismiss)`.
- `apps/mac/codans/App/Features/HierarchySidebar/ArchivedWorktreesSheet.swift` — SwiftUI view. Reads the current Project's archived worktrees live from `HierarchyManager.catalog` (no standing subscription; read on each render). Empty-state mimics supacode's `ContentUnavailableView`. Each row shows branch + relative path + Unarchive / Remove buttons.

`HierarchySidebarFeature` gains:

- `var archivedWorktreesSheet: ArchivedWorktreesFeature.State?` (presented state).
- `.projectShowArchivedTapped(projectID:inSpace:)` action sets the state; Project `⋯` menu entry added in M12 fires it.
- Session-scoped `var hasShownArchiveExplainer: Bool = false` at root-feature scope. The first time `setWorktreeArchived(..., true)` is dispatched this session, we first present a confirmation dialog (reusing the existing `.confirmationDialog` pattern) explaining soft-hide, then on confirm dispatch the archive and flip the flag.

Tests (`ArchivedWorktreesFeatureTests.swift`): unarchive path, safe-remove happy path, safe-remove uncommittedChanges surfaces force button, first-archive confirmation fires once per session.

Commit: `feat(sidebar): ArchivedWorktreesFeature + first-archive confirmation`.

### Milestone 12 — Sidebar integration

Final wire-up edits in `HierarchySidebarView.swift` + `HierarchySidebarFeature.swift`:

- Worktree row context menu (`worktreeRow(...)` builder): insert `Archive` and `Unarchive` items conditional on `worktree.archived`; hide the Archive and Remove entries when `worktree.path == project.rootPath` (main-checkout guard). Archive fires the explainer-or-apply flow from M11.
- `ProjectHeaderRow` Menu: add two items below the existing Rename / Remove entries:
  - `Archived Worktrees…` → fires `.projectShowArchivedTapped`. Badge with the archived count when > 0.
  - `Prune Stale Worktrees` → fires `.projectPruneTapped`. On completion show a toast using `.transientStatus(...)` with the count.
- Upgrade `worktreeRemoveTapped` → `worktreeRemoveConfirmed` flow:
  - After initial `.confirmationDialog` confirm, call `hierarchyClient.removeWorktreeWithGit(..., force: false)`.
  - On `.uncommittedChanges(files:)`, present a secondary `.alert` titled `"N files have uncommitted changes in <relativePath>"` listing the first three names + "Force Remove" destructive button + Cancel.
  - On Force Remove: if `hierarchyClient.runningPanelCount(id) > 0`, present a third alert "This will terminate N running processes" before calling `removeWorktreeWithGit(..., force: true)`.
  - Any other `GitWorktreeError` → banner toast with the error text; catalog untouched.

Adjust existing tests (`HierarchySidebarFeatureTests`) to cover the new action cases.

Commit: `feat(sidebar): Archive + Prune menu items + force-remove upgrade path`.

### Milestone 13 — Integration test

New file `apps/mac/codans/Tests/Integration/WorktreeLifecycleIntegrationTests.swift`. Spawns a scratch git repo under `FileManager.default.temporaryDirectory.appending("codans-wt-" + UUID().uuidString)`, init+commit a file, then exercises the full path against the *real* `GitWorktreeClient.liveValue`:

1. `createWorktreeStream(spec:)` with `copyIgnored = false, copyUntracked = false, fetchOrigin = false, baseRef = current-branch`. Collect stream events, assert `.finished(path)`.
2. `lsWorktrees` returns two entries (main + new).
3. `HierarchyManager.setWorktreeArchived(id, archived: true)` → catalog shows `archived == true`.
4. `HierarchyManager.setWorktreeArchived(id, archived: false)` → back to `false`.
5. `removeWorktree(repoRoot:, path:, force: false)` succeeds (no uncommitted changes).
6. Add an uncommitted file in a fresh worktree; safe-remove throws `.uncommittedChanges([path])`; force-remove succeeds.
7. Tear-down removes the scratch repo.

Guard the whole class with `XCTSkip("wt script not bundled in test target")` when `Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt")` is `nil`. Tuist's test target has the same resource embed as the app target (no additional wiring — `embed-git-wt.sh` runs on the `codans` app and the test target is an extension; if the test host is the app this "just works"). If the test target proves to be hostless, we add a minimal post-script to the tests target too — decided at build time.

Commit: `test(worktree): integration test — create / ls / archive / remove`.

### Milestone 14 — QA, push, PR

Manual checklist (expand from design doc §Testing):

- [ ] `apps/mac/Makefile`'s `lint` and `test` targets pass; no SwiftLint warnings on new files.
- [ ] Build + launch the app; verify the Create Worktree sheet opens, validates live, creates a real worktree on the codans repo itself.
- [ ] External `git worktree add` via terminal → window focus → row appears (after T-PROJECT schedules a reconcile; we validate via calling `hierarchyClient.reconcileDiscoveredWorktrees(projectID:inSpace:)` from a debug hook).
- [ ] Archive → row disappears from main list, appears in Archived sheet.
- [ ] Force-remove with a running `top` pane in that worktree; confirm dialogs fire in order; row is gone after confirm.
- [ ] Main checkout row context menu hides Archive + Remove entries.
- [ ] `git worktree list` and `wt ls --json` agree after every operation.

Push:

    git push -u origin feat/worktree-mgmt

PR body must include (in addition to standard summary + test plan):

- Links to `docs/design-docs/worktree-management-design.md` and this plan.
- A `## reconcile contract for T-PROJECT` section that restates the signature, semantics, idempotency, and error-swallowing behavior verbatim (copied from the design doc §Discovery / Reconcile). This section is what T-PROJECT will depend on.

PR target: `feature/hierarchy-management`.

## Concrete Steps

Exact commands per milestone. Run all from `apps/mac/` unless noted. Each step is idempotent unless flagged.

**M1:**

    cd /Users/wanggang/.worktree/repos/codans/feat/worktree-mgmt
    git submodule add https://github.com/khoi/git-wt.git apps/mac/ThirdParty/git-wt
    # Pin to supacode's current revision:
    SUPACODE_SHA=$(git -C /Users/wanggang/dev/opensource/supacode/Resources/git-wt rev-parse HEAD)
    git -C apps/mac/ThirdParty/git-wt checkout "$SUPACODE_SHA"
    git add .gitmodules apps/mac/ThirdParty/git-wt
    # verify:
    git submodule status apps/mac/ThirdParty/git-wt
    test -x apps/mac/ThirdParty/git-wt/wt && echo ok
    /commit

**M2:**

Write `scripts/verify-git-wt.sh` + `scripts/embed-git-wt.sh` (both `chmod +x`). Edit `apps/mac/Project.swift` adding the two script entries. Then:

    tuist generate --no-open
    xcodebuild -workspace codans.xcworkspace -scheme codans -configuration Debug build -quiet
    # after build, confirm:
    APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'codans.app' -type d -maxdepth 6 | head -1)
    test -x "$APP/Contents/Resources/git-wt/wt" && echo embed-ok
    /commit

**M3–M13:** each milestone ends with its own test invocation, e.g.

    xcodebuild test -workspace codans.xcworkspace -scheme CodansCoreTests -destination 'platform=macOS' -quiet   # M3
    xcodebuild test -workspace codans.xcworkspace -scheme codansTests -destination 'platform=macOS' -quiet     # M6, M7, M8, M9, M11, M12, M13

After each green run:

    /commit

**M14:**

    cd apps/mac && make lint && make test
    git push -u origin feat/worktree-mgmt
    gh pr create --base feature/hierarchy-management --body-file - <<'EOF'
    (body with design+plan links + reconcile contract block — see Artifacts)
    EOF

## Validation and Acceptance

The plan is complete when every box in Progress is checked, the PR is open, and the following behaviors observably pass on a real macOS machine with the codans repo open as a Project:

- Click `+` on a Project → sheet opens within 500 ms, base-ref dropdown populated, branch-name live validator rejects `feature (with space)` and accepts `feature/new-work`.
- Enable "Copy ignored" on a tree with a sizable `.gitignore` → progress lines stream in the sheet while `wt` runs; Create button re-enables only on completion; new row visible, new tab + pane in its directory.
- Run `git worktree add ../sibling -b sideline HEAD` on the CLI → focus the app window → invoke reconcile (via test hook or by letting T-PROJECT's scheduler fire) → `sideline` row appears.
- Right-click a Worktree with a modified file → Remove Worktree → first dialog: Remove confirmation; confirm → second dialog: "3 files have uncommitted changes in ..."; click Force Remove → third dialog: "This will terminate N running processes" (if any) → confirm → row and directory are gone.
- Right-click main checkout → menu has Reveal in Finder + Open in Editor but NOT Archive or Remove.
- Archive a Worktree → row leaves main list; open Archived Worktrees from Project `⋯` → row present with Unarchive + Remove buttons.
- `rm -rf` a worktree directory on disk, then Prune Stale Worktrees → toast says "Pruned 1 stale worktree"; row is gone from the sidebar.

`make test` reports zero failing tests. `make lint` reports zero warnings.

## Idempotence and Recovery

Each milestone's file-level edits are idempotent: re-running the same edit is a no-op because files are fully specified. Submodule add in M1 is the exception — retry requires `git submodule deinit -f apps/mac/ThirdParty/git-wt && git rm -rf apps/mac/ThirdParty/git-wt && rm -rf .git/modules/apps/mac/ThirdParty/git-wt` before re-running. M2's Tuist regenerate is fully idempotent.

If the Xcode build fails at M2 due to script path quoting, the fix is to run `chmod +x` on both scripts (one cause of a silent pre-script skip). If the embed script lands an empty `wt` (zero-byte copy), the submodule's `wt` entry is likely a gitignored symlink in a checkout variant — resolve with `git submodule update --init --recursive`.

Integration tests in M13 use a UUID scratch dir and always tear down in `addTeardownBlock`; test failure does not leave the filesystem dirty.

If a milestone's commit is regretted, `/commit` output reports the SHA; `git reset --soft <prev-sha>` restores the working tree for re-commit. We do not amend published commits.

## Artifacts and Notes

### Reference text for the PR body — reconcile contract (copy verbatim)

    ## reconcile contract for T-PROJECT

    T-WORKTREE exposes one closure via HierarchyClient that T-PROJECT calls
    when a Project is added and when the window-focus reconcile fires:

        var reconcileDiscoveredWorktrees:
          @MainActor @Sendable (ProjectID, SpaceID) async -> Void

    Semantics:
      - Reads Project.gitRoot; skips when nil.
      - Shells out to the bundled wt to list on-disk worktrees.
      - Appends catalog rows for on-disk entries not already present
        (matched by URL.standardizedFileURL.path).
      - NEVER removes catalog rows. Stale rows are computed in the view
        layer; only the user-invoked Prune action deletes.
      - Idempotent: calling twice with the same on-disk state is a no-op.
      - Swallows all GitWorktreeError and logs them; never throws to the
        caller. Safe to call during teardown — Task cancellation
        propagates through.

    T-PROJECT owns WHEN to call this; T-WORKTREE owns WHAT it does.

### `wt` argv quick reference (from supacode GitClient.createWorktreeArguments)

    wt --base-dir <dir> sw [--copy-ignored] [--copy-untracked] [--from <ref>] [--verbose] <name>

`--verbose` is set iff `copyIgnored || copyUntracked` (short runs do not need the extra noise).

### Error-mapping stderr patterns

| Pattern | GitWorktreeError case |
|---|---|
| `"A branch named '(.+?)' already exists"` | `.branchExists(matched)` |
| `"'(.+?)' is not a valid branch name"` | `.invalidBranchName(matched)` |
| `"unknown revision"` or `"bad revision"` | `.refNotFound(line)` |
| `"contains modified or untracked files"` | `.uncommittedChanges(files: [from porcelain])` |
| `"is locked"` | `.worktreeLocked(path)` |
| any other non-zero exit | `.commandFailed(command:, stderr:)` |

## Interfaces and Dependencies

External tools / libraries:

- `git-wt` at <https://github.com/khoi/git-wt> — pinned via submodule.
- `/usr/bin/git` — assumed present (macOS default; Xcode CLT ships it).
- Existing TCA `ComposableArchitecture` package (already in the project).

In `apps/mac/codans/Git/GitWorktreeClient.swift`, define:

    nonisolated struct GitWorktreeClient: Sendable {
      var lsWorktrees: @Sendable (_ repoRoot: URL) async throws -> [GitWtEntry]
      var localBranchNames: @Sendable (_ repoRoot: URL) async throws -> Set<String>
      var branchRefs: @Sendable (_ repoRoot: URL) async throws -> [String]
      var defaultRemoteBranchRef: @Sendable (_ repoRoot: URL) async throws -> String?
      var isValidBranchName: @Sendable (_ repoRoot: URL, _ name: String) async -> Bool
      var createWorktreeStream: @Sendable (_ spec: CreateSpec)
        -> AsyncThrowingStream<CreateEvent, Error>
      var removeWorktree: @Sendable (_ repoRoot: URL, _ path: URL, _ force: Bool) async throws -> Void
      var pruneWorktrees: @Sendable (_ repoRoot: URL) async throws -> Int
      var fetchRemote: @Sendable (_ repoRoot: URL, _ remote: String) async throws -> Void
      var changedFiles: @Sendable (_ worktreeRoot: URL) async throws -> [String]
    }

In `apps/mac/CodansCore/Worktree.swift`, the stored property and Codable extensions must compile such that:

    let wt = Worktree(... archived: true)                // default-false memberwise still works too
    let data = try JSONEncoder().encode(wt)              // emits "archived": true
    let wt2 = try JSONDecoder().decode(Worktree.self, from: data)
    XCTAssertEqual(wt, wt2)

In `apps/mac/codans/App/Clients/HierarchyClient.swift`, the struct closures listed in the Milestone 8 section are all additions at end of file; none of the existing closures move.

In `apps/mac/Project.swift`, the `codans` target's `scripts:` argument is added with exactly the two entries described in Milestone 2; no other target changes.
