# ExecPlan: Worktree Management follow-ups (Issue #24)

**Status:** Draft
**Author:** Gump (T-WORKTREE sub-agent, via Claude Code)
**Date:** 2026-04-21

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After this change, the Worktree Management surface merged in PR #20 is hardened in five specific ways that review caught but deferred. The user-visible upshot:

- Cancelling the Create Worktree sheet while `wt` is mid-copy no longer leaves a detached `wt` process spinning on the user's machine — Task cancellation actually terminates the child.
- Error banners surfacing "Branch already exists" and "Invalid branch name" fire regardless of git's locale / casing choice for those messages, matching the other error classifications that were already case-insensitive.
- The Create flow reports the *correct* worktree path even if a future `git-wt` release prints a trailing summary line — we now identify the new worktree by diffing `wt ls --json` before and after, with stdout's last-non-empty line retained only as a belt-and-braces tiebreaker.
- When a background reconcile hits a `wt ls` failure, the error lands in `os_log` instead of vanishing — operators can grep the logs instead of guessing.
- Running the integration test on a host without `wt` bundled produces a clean `skipped` status rather than a spurious red failure.

No user-visible UX change; all fixes are resilience / correctness / operability. Closes **Issue #24**.

## Progress

- [x] T1 — (e) `WorktreeLifecycleIntegrationTests` switch from `#require(wtAvailable(), …)` (counts as failure) to `.enabled(if: Self.wtBundled)` trait (counts as skip) — needed `nonisolated` on the static let because the @MainActor struct would otherwise make the predicate MainActor-isolated and the trait context is Sendable; 2 tests pass in 2.1s
- [x] T2 — (d) `HierarchyClient.reconcile` catch wires an `os_log` `Logger.error(...)` call; comment updated. Subsystem `com.gumpw.codans.hierarchy`, category `reconcile` (matches SettingsStore / CatalogStore / IPC handlers' `com.gumpw.codans.<area>` convention). `OSLog` import added.
- [x] T3 — (b) `GitWorktreeClient.mapGitStderr` regexes all case-insensitive (inline `(?i)` on the two regex branches; `stderr.lowercased()` branches unchanged); three mixed-case tests added (uppercase / title-case for branchExists, mixed for invalidBranchName). 21 tests in suite, all green.
- [x] T4 — (a) `GitWorktreeShell.runStream` exposes `onSpawn` callback; `createWorktreeStream`'s `continuation.onTermination` terminates the captured Process via `CreateWorktreeProcessBox` (NSLock-backed) before task cancellation; `makeLive(onCreateWorktreeSpawn:)` adds an optional test seam letting the integration test capture a weak Process reference and assert `!isRunning` within 2 s of cancel. Test completes in ~350 ms — far under deadline, no flake risk from wt speed. 3 integration tests green.
- [x] T5 — (c) `createWorktreeStream` picks the new worktree path by diffing `wt ls --json` before/after via `pickNewWorktreePath` static pure helper; `stdoutLast` retained only as tiebreaker for multi-entry diffs. 5 unit tests cover clean diff / empty diff / multiple-new-w-fallback / multiple-new-no-match / trailing-slash canonicalization. `fullLifecycle` integration test extended with an assertion that the returned path shows up in `wt ls --json` output. 26 unit + 3 integration = 29 tests green.
- [x] T6 — full local validation (swiftlint clean + 894 tests green across all four schemes), push, PR #29 opened against `feature/hierarchy-management`, PR_READY pushed to master.

## Surprises & Discoveries

(None yet)

## Decision Log

- **D1** — Test-skip pattern (task e): the project already has the
  pattern `.enabled(if: Self.xxxEnabled)` with `static let xxxEnabled = {
  ... }()` at type init (see
  `apps/mac/codans/Tests/GitTests/LiveGitServiceIntegrationTests.swift:12-16`
  and `apps/mac/codans/Tests/EditorTests/LiveProcessSpawnerIntegrationTests.swift:20`).
  We reuse it rather than introducing `throw XCTSkip`. Swift Testing's
  `.enabled(if:)` trait evaluates the predicate at test discovery, so a
  false value produces a clean "skipped" count. The predicate calls
  `Bundle.main.url(forResource:subdirectory:)` which is safe at static-let
  init time.
- **D2** — Process cancellation plumbing (task a): extend
  `GitWorktreeShell.runStream` with an `onSpawn: @Sendable (Process) ->
  Void` callback. The caller in `createWorktreeStream` stores the Process
  in a small locked box and calls `.terminate()` from
  `continuation.onTermination`. Alternative — returning a streaming
  handle that carries a cancellation token — would force a wider API
  shape and doesn't buy anything given `runStream` has exactly one
  caller today.
- **D3** — Path picking (task c): extract
  `static func pickNewWorktreePath(preEntries:postEntries:fallbackStdoutLast:)`
  for testability. The integration stays light: instead of trying to
  induce a trailing stdout line from the real `wt` (hard without
  forking), the integration test asserts the final path is in the live
  `wt ls --json` output, which by construction proves the diff-based
  picker returned a real entry's path (stdoutLast only breaks that
  invariant if wt is lying about what it created, which is out of our
  scope).
- **D4** — Regex case-insensitivity (task b): use the Swift Regex
  literal's inline `(?i)` option. Applies case-insensitivity only to the
  two branches that need it (`branchExists`,
  `invalidBranchName`), keeps the captured branch-name substring in its
  original case (so errors show "A branch named 'X' already exists"
  faithfully instead of lowercasing user input). The three branches
  that already use `stderr.lowercased()` stay untouched — their patterns
  are English literals that don't interact with captures.
- **D5** — Logger subsystem naming (task d): follow the project's
  existing convention. `grep -n "Logger(subsystem" apps/mac/codans/`
  picks up the authoritative spelling during T2. If no prior art exists,
  default to `com.gumpw.codans.hierarchy` / category `reconcile` and
  declare at file scope for `HierarchyClient.swift`.
- **D6** — Task ordering: land the test-only fixes first (T1, T2, T3)
  so the fast-feedback suite is clean before touching the streaming
  code. T4 and T5 both mutate `createWorktreeStream`; T4 first (adds
  `onSpawn` parameter to `runStream`), T5 second (uses
  `pickNewWorktreePath` + snapshots) so we don't fight self on the same
  closure twice.

## Outcomes & Retrospective

All 6 tasks landed on 2026-04-21. PR #29 open to
`feature/hierarchy-management`.

What went smooth:

- `.enabled(if: Self.wtBundled)` pattern is already idiomatic in the
  repo — T1 was copy-paste from `LiveGitServiceIntegrationTests`.
- The T4 `onCreateWorktreeSpawn` testing seam let the integration
  test assert on the literal invariant master asked for
  (`!process.isRunning` within 2 s of cancel). No file-based
  heuristics, no flake risk.
- `pickNewWorktreePath`'s pure shape made the 5 edge-case tests
  trivial — no fake process runner needed.

Minor execution surprises:

- T1: the struct was `@MainActor`, so the `static let` inherited
  MainActor isolation and the `.enabled(if:)` trait's Sendable
  predicate couldn't call it. Fix: prepend `nonisolated` to the
  static let. Worth recording for future trait adoption on any
  other @MainActor test struct.
- T4: `CreateWorktreeProcessBox` needed an explicit `nonisolated`
  annotation on the class declaration for the same default-MainActor
  reason — accessing its methods from the onSpawn / onTermination
  closures (both Sendable, non-isolated) hit the same diagnostic.
- T6 lint: a duplicate blank line crept in after the ProcessBox
  class. Separate tiny style-only commit b329d0c rather than
  amending T4.

Closes #24 once PR #29 lands.

## Context and Orientation

Related documents:

- Product spec: `docs/product-specs/worktree-management.md`
- Design doc: `docs/design-docs/worktree-management-design.md`
- Predecessor plan (merged in PR #20): `docs/exec-plans/0010-worktree-management.md`
- Issue: <https://github.com/wanggang316/codans/issues/24>
- PR #20 (merged squash): <https://github.com/wanggang316/codans/pull/20>

Key source files (full repository-relative paths):

- `apps/mac/codans/Git/GitWorktreeClient.swift` — owns the
  `GitWorktreeClient` Sendable struct, `GitWorktreeShell.runStream`,
  `createWorktreeStream` closure, `mapGitStderr` helper. Tasks **a**,
  **b**, **c** all edit this file.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — holds the
  `reconcile(...)` helper with the silent-swallow catch. Task **d**
  adds a logger call here only. Note: this file has grown significantly
  since PR #20 (T-PROJECT + T-SPACE additions); our edit is purely
  additive inside the existing `reconcile` private static method.
- `apps/mac/codans/Tests/GitWorktreeClientTests.swift` — unit
  tests for the pure helpers. Tasks **b** and **c** add cases here.
- `apps/mac/codans/Tests/Integration/WorktreeLifecycleIntegrationTests.swift`
  — end-to-end integration test against a temp git repo + bundled
  `wt`. Tasks **a**, **c**, **e** all touch this file (add a cancel
  test; assert diff-based path round-trips through a real `wt ls`;
  switch from `#require` to `.enabled(if:)`).
- Reference pattern for skip-trait: `apps/mac/codans/Tests/GitTests/LiveGitServiceIntegrationTests.swift:11-20`
  — canonical `.enabled(if: Self.xxxEnabled)` + `static let xxxEnabled
  = { ... }()` pattern.

Terms of art:

- **AsyncThrowingStream.onTermination** — Swift stdlib callback on an
  `AsyncThrowingStream`'s continuation. Fires when the consumer
  finishes the stream, when the Task awaiting the stream is cancelled,
  or when `continuation.finish()` is called. Where we wire the Process
  terminate.
- **Swift Testing `.enabled(if:)` trait** — a `@Test` trait that
  evaluates a Boolean at test discovery time; `false` marks the test
  `skipped`, not `failed`.
- **`GitWtEntry`** — the `Decodable` struct holding the `{ branch,
  path, head, is_bare }` shape emitted by `wt ls --json`. Defined in
  `GitWorktreeClient.swift`; used for the pre/post diff in task (c).

## Plan of Work

The plan runs as five independent tasks plus a wrap-up push. Each
task is a separate commit; tasks T1–T3 are test-only or
observability-only and trivially independent. T4 and T5 both touch
`createWorktreeStream`'s body; ordering matters there. T6 is the
final lint + push + PR open.

### T1 — `.enabled(if:)` skip trait (Issue #24 e)

In `apps/mac/codans/Tests/Integration/WorktreeLifecycleIntegrationTests.swift`,
replace the top-of-body `try #require(wtAvailable(), "wt script not
bundled in test target")` in both test methods with a Swift Testing
trait. The existing `wtAvailable()` instance method becomes a `static
let wtBundled: Bool = { Bundle.main.url(forResource: "wt",
withExtension: nil, subdirectory: "git-wt") != nil }()` and each
`@Test` gains `.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled)`.

Verification: `xcodebuild test -scheme codans-Workspace -only-testing:codansTests/WorktreeLifecycleIntegrationTests`
on a host where `wt` IS bundled → both tests run + pass. On a
hypothetical host without bundling, both show as "skipped" at test
discovery. We can't easily simulate the unbundled host locally (the
app build embeds `wt` into `Codans.app/Contents/Resources/git-wt/`
and the test host inherits), so the plan accepts type-discovery
correctness as sufficient evidence.

Commit message (verbatim): `test(worktree): skip integration tests via .enabled(if:) when wt absent`.

### T2 — Logger in `HierarchyClient.reconcile` catch (Issue #24 d)

In `apps/mac/codans/App/Clients/HierarchyClient.swift`:

1. Before editing, run `grep -n "Logger(subsystem" apps/mac/codans/`
   to pick the project's existing subsystem naming (decision D5).
2. At file scope (between the imports and the `extension
   HierarchyClient`), add
   `private let reconcileLogger = Logger(subsystem: "<project-subsystem>", category: "reconcile")`.
   Import `os.log` if not already present.
3. In the `reconcile(projectID:spaceID:manager:gitWorktreeClient:)`
   private static method's catch block, replace the "Logged at call
   site" fib with:
   ```
   reconcileLogger.error(
     "reconcileDiscoveredWorktrees failed: project=\(projectID.raw.uuidString, privacy: .public) \(error.localizedDescription, privacy: .public)"
   )
   ```
4. Update the catch's leading comment to describe what's logged —
   drop the "Follow-up PR wires a Logger call" breadcrumb.

Verification: `xcodebuild build -scheme codans` succeeds; no test
regressions. Manual spot-check that a synthetic throw from
`gitWorktreeClient.lsWorktrees` produces a log line via `log stream
--predicate 'subsystem == "<project-subsystem>"'`.

Commit message: `fix(hierarchy): log reconcileDiscoveredWorktrees failures via os_log`.

### T3 — `mapGitStderr` case-insensitive (Issue #24 b)

In `apps/mac/codans/Git/GitWorktreeClient.swift`, the two
case-sensitive regex branches inside `mapGitStderr`:

```swift
if let match = stderr.firstMatch(of: /A branch named '([^']+)' already exists/) { ... }
if let match = stderr.firstMatch(of: /'([^']+)' is not a valid branch name/) { ... }
```

Prefix each literal with `(?i)`:

```swift
if let match = stderr.firstMatch(of: /(?i)A branch named '([^']+)' already exists/) { ... }
if let match = stderr.firstMatch(of: /(?i)'([^']+)' is not a valid branch name/) { ... }
```

Swift Regex literals accept inline flags — verified against the Swift
Regex documentation and in-repo usage in
`apps/mac/codans/Git/GitOutputParser.swift` (which already uses
Regex literals for git output parsing). The existing three
lowercased-stderr branches (`unknown revision`, `bad revision`,
`is locked`, `contains modified or untracked files`) stay as-is —
they run on `stderr.lowercased()` and don't interact with captures.

In `apps/mac/codans/Tests/GitWorktreeClientTests.swift`, extend
the existing stderr-mapping tests with mixed-case fixtures. Keep
the existing tests; add siblings:

- `testStderrMapsBranchExistsUppercase` — stderr `"FATAL: A BRANCH NAMED 'X' ALREADY EXISTS"` → `.branchExists("X")`.
- `testStderrMapsBranchExistsTitleCase` — stderr `"Fatal: A Branch Named 'feat' Already Exists"` → `.branchExists("feat")`.
- `testStderrMapsInvalidBranchNameMixedCase` — stderr `"Fatal: 'Bad Name' Is Not A Valid Branch Name"` → `.invalidBranchName("Bad Name")`.

The existing `testStderrMapsBranchExists` and
`testStderrMapsInvalidBranchName` cover the lowercase default path.

Verification: `xcodebuild test -only-testing:codansTests/GitWorktreeClientTests`
reports the full 18 + 3 = 21-test suite green.

Commit message: `fix(git): make mapGitStderr case-insensitive for branch-name errors`.

### T4 — Process termination on cancel (Issue #24 a)

Two parts: extend `runStream` with an `onSpawn` callback, then wire
the `createWorktreeStream` closure's `continuation.onTermination` to
terminate the captured Process.

**Part 1: `runStream` gets an `onSpawn` parameter.** In
`GitWorktreeShell.runStream` (around
`apps/mac/codans/Git/GitWorktreeClient.swift:241`):

```swift
static func runStream(
  executable: URL,
  arguments: [String],
  cwd: URL,
  onSpawn: @Sendable (Process) -> Void = { _ in },
  onStdout: @escaping @Sendable (String) -> Void,
  onStderr: @escaping @Sendable (String) -> Void
) async -> (exitCode: Int32, stdoutLast: String, stderrCollected: String, spawnFailedReason: String?)
```

Call `onSpawn(process)` **before** `try process.run()`. The default
value keeps the signature backwards compatible; only
`createWorktreeStream` sets it.

**Part 2: `createWorktreeStream` captures + terminates.** Inside the
closure body (line ~477–540):

```swift
createWorktreeStream: { spec in
  AsyncThrowingStream { continuation in
    // Locked box so onTermination (not MainActor-isolated, fires
    // on any thread) can safely read/clear the Process reference
    // while the Task's consumer thread assigns it.
    final class ProcessBox: @unchecked Sendable {
      private let lock = NSLock()
      private var process: Process?
      func set(_ p: Process) { lock.lock(); process = p; lock.unlock() }
      func terminateIfRunning() {
        lock.lock(); defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        process.terminate()
      }
    }
    let processBox = ProcessBox()

    let task = Task {
      do {
        // ... existing fetch + args build code ...
        let outcome = await GitWorktreeShell.runStream(
          executable: wt,
          arguments: args,
          cwd: spec.repoRoot,
          onSpawn: { process in processBox.set(process) },
          onStdout: { line in continuation.yield(.progressLine(line)) },
          onStderr: { line in continuation.yield(.progressLine(line)) }
        )
        // ... existing outcome-handling code ...
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in
      processBox.terminateIfRunning()
      task.cancel()
    }
  }
}
```

The order (`terminate` before `task.cancel`) matters: terminating the
Process makes `runStream`'s `withCheckedContinuation` resume via its
`terminationHandler`, which lets the Task's `do { ... }` complete
naturally and call `continuation.finish(throwing:)`. Cancelling the
Task first would orphan the resumption.

**Integration test**
(`WorktreeLifecycleIntegrationTests.swift`): add

```swift
@Test(.enabled(if: WorktreeLifecycleIntegrationTests.wtBundled))
func createStreamCancellationTerminatesWtProcess() async throws {
  let repo = try makeTempRepo()
  defer { try? fm.removeItem(at: repo) }
  let client = GitWorktreeClient.makeLive()
  let baseDir = repo.appending(path: ".worktrees", directoryHint: .isDirectory)
  try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

  // copyIgnored = true asks wt to do measurable work on .git's ignored
  // files (node_modules-style). We race the stream's first
  // progressLine against a cancel window.
  let spec = CreateWorktreeSpec(
    repoRoot: repo, baseDirectory: baseDir,
    name: "cancelled", branch: "cancelled",
    baseRef: "HEAD",
    fetchOrigin: false,
    copyIgnored: true, copyUntracked: false
  )

  let stream = client.createWorktreeStream(spec)
  let consumingTask = Task<Void, Error> {
    for try await event in stream {
      if case .progressLine = event {
        // Got proof wt started; now cancel.
        throw CancellationError()
      }
    }
  }

  // Give wt up to 2 s to emit its first line; if nothing arrives, the
  // tree is too small to stream and we cancel unconditionally.
  try await Task.sleep(for: .seconds(2))
  consumingTask.cancel()
  // Wait for the cancellation to propagate and the Process to exit.
  // If the wt process leaks, this sleep is wasted but the next
  // assertion catches it via the on-disk directory check.
  try await Task.sleep(for: .seconds(1))

  // Proof: the worktree directory should NOT exist (wt terminated
  // before completing). If wt kept running, it would have finished
  // the (tiny) copy and left the directory in place.
  let target = baseDir.appending(path: "cancelled")
  #expect(!fm.fileExists(atPath: target.path(percentEncoded: false)))
}
```

Verification: the new test runs under 5 s when the fix is in place
(wt receives SIGTERM promptly). Without the fix, `wt` completes its
tiny work and the directory exists, failing the `#expect(!...)`.

Commit message: `fix(git): terminate wt on createWorktreeStream cancellation`.

### T5 — Diff-based path picking (Issue #24 c)

**Pure helper in `GitWorktreeClient.swift`:**

```swift
nonisolated extension GitWorktreeClient {
  /// Identifies the created worktree by diffing `wt ls --json` before
  /// vs after the create. The single new entry (keyed by canonicalized
  /// path) is the answer. When more than one entry is new
  /// (unexpected — implies a concurrent worktree create — or if
  /// upstream `wt` ever starts reporting auxiliary entries), falls
  /// back to matching `fallbackStdoutLast` against the new set.
  /// Returns nil when the diff is empty (caller should surface
  /// `.commandFailed` because wt claimed success but created nothing).
  static func pickNewWorktreePath(
    preEntries: [GitWtEntry],
    postEntries: [GitWtEntry],
    fallbackStdoutLast: String
  ) -> URL? {
    func canonical(_ path: String) -> String {
      URL(fileURLWithPath: path).standardizedFileURL.path
    }
    let prePaths = Set(preEntries.map { canonical($0.path) })
    let newEntries = postEntries.filter { !prePaths.contains(canonical($0.path)) }
    if newEntries.count == 1 {
      return URL(fileURLWithPath: newEntries[0].path).standardizedFileURL
    }
    if newEntries.isEmpty {
      return nil
    }
    let fallbackCanonical = canonical(fallbackStdoutLast)
    if !fallbackStdoutLast.isEmpty,
       let match = newEntries.first(where: { canonical($0.path) == fallbackCanonical }) {
      return URL(fileURLWithPath: match.path).standardizedFileURL
    }
    // Multiple new entries and fallback doesn't disambiguate — take
    // the first to keep the happy path unblocked. Caller logs a
    // warning via the reconcileLogger.
    return URL(fileURLWithPath: newEntries[0].path).standardizedFileURL
  }
}
```

**`createWorktreeStream` wiring:**

1. Before running `wt sw`, snapshot: `let preEntries = (try? await
   lsWorktreesInternal(repoRoot: spec.repoRoot)) ?? []`. Where
   `lsWorktreesInternal` is the same code that `lsWorktrees` closure
   uses, extracted to a private static func so we can call it off the
   closure. (If extraction is awkward, inline the `wt ls --json` call
   here — it's a handful of lines.)
2. After `.exited(0)` and the existing `outcome.stdoutLast` empty-check
   is removed (we no longer need stdoutLast to be non-empty
   pre-emptively), capture `postEntries` the same way.
3. Call `pickNewWorktreePath(preEntries: postEntries: fallbackStdoutLast:
   outcome.stdoutLast)`. If nil, `continuation.finish(throwing:
   .commandFailed(command:, stderr: "wt exited 0 but no new worktree
   appeared in wt ls"))`. Otherwise yield `.finished(worktreePath:
   <result>)`.

**Unit tests in `GitWorktreeClientTests.swift`:**

- `pickNewWorktreePathCleanDiffReturnsNewPath` — pre has `main`,
  post has `main` + `feature`, fallback empty → returns `.../feature`.
- `pickNewWorktreePathNoDiffReturnsNil` — pre == post, fallback empty →
  returns nil.
- `pickNewWorktreePathMultipleNewDisambiguatesByFallback` — post has
  two new entries, fallback matches one → returns that one.
- `pickNewWorktreePathMultipleNewNoMatchReturnsFirst` — post has two
  new entries, fallback doesn't match any → returns the first (warning
  path).
- `pickNewWorktreePathIgnoresBareEntries` — implicit: lsWorktrees
  already filters `is_bare`, so we don't need a test case here unless
  the helper gets bare entries passed in. Skip to keep the test suite
  tight.

**Integration test update**: in the existing `fullLifecycle` test, after
`createWorktreeStream`'s `.finished`, add

```swift
let listed = try await client.lsWorktrees(repo)
#expect(listed.contains { URL(fileURLWithPath: $0.path).standardizedFileURL == createdPath })
```

which proves the returned path is a real entry in `wt ls --json`, not
some parsed-stdout accident.

Verification:
`xcodebuild test -only-testing:codansTests/GitWorktreeClientTests
-only-testing:codansTests/WorktreeLifecycleIntegrationTests` green.

Commit message: `fix(git): derive created worktree path from wt ls diff, not stdoutLast`.

### T6 — Validation + PR

1. `cd apps/mac && make lint` — expect zero warnings.
2. `xcodebuild test -workspace codans.xcworkspace -scheme codans-Workspace -destination 'platform=macOS'` — all four schemes green.
3. `git push -u origin fix/worktree-followups`.
4. `gh pr create --base feature/hierarchy-management --title "Worktree Management follow-ups (Issue #24)" --body-file <body>`. Body lists (a)–(e), each with commit SHA, ends with "Closes #24".
5. `prowl send` to master with `PR_READY: <url>`.

## Concrete Steps

Exact commands per task. Run from `apps/mac/` unless noted.

**T1:**

    # Edit WorktreeLifecycleIntegrationTests.swift — add static let + .enabled(if:) on both tests
    xcodebuild test -workspace codans.xcworkspace -scheme codans-Workspace -destination 'platform=macOS' -only-testing:codansTests/WorktreeLifecycleIntegrationTests
    # Expect: 2 tests passed / 0 failed; no #require.
    /commit

**T2:**

    grep -n "Logger(subsystem" apps/mac/codans/  # pick the right subsystem name
    # Edit HierarchyClient.swift — add reconcileLogger at file scope + Logger.error() in catch
    xcodebuild build -workspace codans.xcworkspace -scheme codans -configuration Debug
    /commit

**T3:**

    # Edit GitWorktreeClient.swift — add (?i) to the two branch regexes
    # Edit GitWorktreeClientTests.swift — add three mixed-case tests
    xcodebuild test -workspace codans.xcworkspace -scheme codans-Workspace -destination 'platform=macOS' -only-testing:codansTests/GitWorktreeClientTests
    # Expect: 21 tests passed / 0 failed.
    /commit

**T4:**

    # Edit GitWorktreeClient.swift:
    #   - runStream gains onSpawn callback (default noop)
    #   - createWorktreeStream wires onSpawn → ProcessBox → onTermination
    # Add createStreamCancellationTerminatesWtProcess to WorktreeLifecycleIntegrationTests.swift
    xcodebuild test -workspace codans.xcworkspace -scheme codans-Workspace -destination 'platform=macOS' -only-testing:codansTests/WorktreeLifecycleIntegrationTests
    # Expect: 3 tests passed; cancel test completes within 10 s and the worktree dir doesn't exist.
    /commit

**T5:**

    # Edit GitWorktreeClient.swift:
    #   - Add pickNewWorktreePath helper
    #   - Rework createWorktreeStream to diff lsWorktrees snapshots
    # Edit GitWorktreeClientTests.swift — 4 pickNewWorktreePath cases
    # Edit WorktreeLifecycleIntegrationTests.swift fullLifecycle to assert ls contains created path
    xcodebuild test -workspace codans.xcworkspace -scheme codans-Workspace -destination 'platform=macOS' -only-testing:codansTests/GitWorktreeClientTests -only-testing:codansTests/WorktreeLifecycleIntegrationTests
    /commit

**T6:**

    cd apps/mac && make lint
    xcodebuild test -workspace codans.xcworkspace -scheme codans-Workspace -destination 'platform=macOS'
    git push -u origin fix/worktree-followups
    gh pr create --base feature/hierarchy-management --title "Worktree Management follow-ups (Issue #24)" --body-file - <<'EOF'
    <body: 5 items with commit SHAs, "Closes #24">
    EOF
    # Then: prowl send PR_READY to master.

## Validation and Acceptance

The plan is complete when, on `fix/worktree-followups` tip:

- `cd apps/mac && make lint` → zero warnings.
- Full workspace test run → every suite passes; in particular
  `GitWorktreeClientTests` has ≥ 22 tests (18 original + 3 mixed-case +
  4 pickNewWorktreePath) and `WorktreeLifecycleIntegrationTests` has 3
  tests (fullLifecycle + uncommittedChanges +
  createStreamCancellationTerminates).
- Running `WorktreeLifecycleIntegrationTests` on a host without `wt`
  bundled (simulated by grep: `@Test(.enabled(if:` on every @Test
  decoration and `static let wtBundled: Bool = …`) marks those tests
  `skipped`, not `failed`.
- Cancelling a `createWorktreeStream` consumer mid-progress kills the
  child `wt` process within ≤ 2 s (covered by T4's integration test).
- A synthetic `reconcile` failure produces a log line under the chosen
  subsystem / category (spot-checked manually).
- `mapGitStderr` returns `.branchExists("X")` for all of "A branch
  named 'X' already exists", "A BRANCH NAMED 'X' ALREADY EXISTS",
  and "A Branch Named 'X' Already Exists" (covered by T3's new
  tests).

## Idempotence and Recovery

Each task is additive — a retry after a partial failure is safe. The
only cross-task file is `GitWorktreeClient.swift`, which T3, T4, T5
all edit; they edit disjoint regions (regex literals, `runStream`
signature + createWorktreeStream body, new static helper), so a
merge conflict between retried tasks is essentially impossible.

If a `make lint` failure surfaces in T6, fix inline and amend the
last commit (OR squash at merge time — `feature/hierarchy-management`
uses squash merge per PR #20's precedent).

If `git push` rejects the branch (`fix/worktree-followups` already
exists remote), `git push --force-with-lease` is appropriate — this
branch has no other collaborators.

## Artifacts and Notes

### Reference for the final PR body (T6)

    ## Summary

    Five follow-up fixes to PR #20 (Worktree Management). Each maps
    1:1 to an item in Issue #24.

    ### Fixes

    - (a) `GitWorktreeClient.createWorktreeStream` now terminates the
      spawned `wt` process when the consuming Task is cancelled — no
      more leaked children when the Create Worktree sheet is
      dismissed mid-copy. <commit-SHA-T4>
    - (b) `mapGitStderr` matches "A branch named 'X' already exists"
      and "'X' is not a valid branch name" case-insensitively, matching
      the other `stderr.lowercased()` branches. <commit-SHA-T3>
    - (c) Created worktree path is now derived from a pre/post diff of
      `wt ls --json` instead of the brittle "last non-empty stdout
      line" heuristic; `stdoutLast` kept only as a tiebreaker when the
      diff is ambiguous. <commit-SHA-T5>
    - (d) `HierarchyClient.reconcile` catch block now logs via
      `os_log` under the project's existing hierarchy subsystem; was
      silently swallowing. <commit-SHA-T2>
    - (e) `WorktreeLifecycleIntegrationTests` uses Swift Testing's
      `.enabled(if:)` trait so hosts without the bundled `wt` script
      get a clean "skipped" status instead of a red "failed".
      <commit-SHA-T1>

    ## Test plan

    - [x] `make mac-lint` green
    - [x] Full test suite green (all four schemes)
    - [x] `GitWorktreeClientTests` has mixed-case stderr + pickNewWorktreePath
    - [x] `WorktreeLifecycleIntegrationTests` has the cancellation test +
      the ls-contains assertion in fullLifecycle

    Closes #24

## Interfaces and Dependencies

No new external dependencies. Internal APIs touched:

In `apps/mac/codans/Git/GitWorktreeClient.swift`:

    // T4 — new parameter, default preserves existing callers
    static func runStream(
      executable: URL,
      arguments: [String],
      cwd: URL,
      onSpawn: @Sendable (Process) -> Void = { _ in },
      onStdout: @escaping @Sendable (String) -> Void,
      onStderr: @escaping @Sendable (String) -> Void
    ) async -> (exitCode: Int32, stdoutLast: String, stderrCollected: String, spawnFailedReason: String?)

    // T5 — new pure helper
    static func pickNewWorktreePath(
      preEntries: [GitWtEntry],
      postEntries: [GitWtEntry],
      fallbackStdoutLast: String
    ) -> URL?

In `apps/mac/codans/App/Clients/HierarchyClient.swift`:

    // T2 — new file-scope Logger
    private let reconcileLogger = Logger(subsystem: <chosen subsystem>, category: "reconcile")

No public-API changes. `GitWorktreeClient` struct shape, `CreateWorktreeSpec`,
`CreateWorktreeEvent`, `GitWorktreeError`, `HierarchyClient` closures are
all unchanged.
