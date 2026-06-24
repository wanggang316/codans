import ComposableArchitecture
import Foundation

// MARK: - Public value types

/// JSON shape returned by `wt ls --json`. Field names match the upstream
/// `git-wt` output; `is_bare` maps to `isBare` via `CodingKeys`.
nonisolated struct GitWtEntry: Decodable, Equatable, Sendable {
  let branch: String
  let path: String
  let head: String
  let isBare: Bool

  enum CodingKeys: String, CodingKey {
    case branch, path, head
    case isBare = "is_bare"
  }
}

/// Outcome of the best-effort local-branch deletion run during worktree
/// removal. `kept` means git refused (branch checked out by the main
/// checkout or another worktree) — removal still succeeds, the branch is
/// intentionally left intact, and `reason` carries git's message so the
/// caller can surface why the branch survived.
nonisolated enum BranchDeleteOutcome: Equatable, Sendable {
  case deleted
  case absent
  case kept(reason: String)
}

/// Input spec for `createWorktreeStream`. The caller pre-sanitizes `name`
/// to the on-disk directory name (via `GitWorktreeClient.sanitizeBranchName`
/// or an equivalent), which may differ from `branch` when the branch name
/// contains characters that aren't safe as a directory name.
nonisolated struct CreateWorktreeSpec: Equatable, Sendable {
  var repoRoot: URL
  var baseDirectory: URL
  var name: String
  var baseRef: String
  var fetchOrigin: Bool
  var copyIgnored: Bool
  var copyUntracked: Bool
  /// True when a local branch named `name` already exists but no live
  /// worktree is checked out on it — a "dangling" branch left behind
  /// when a prior remove's `git branch -D` was skipped (empty catalog
  /// branch) or refused (branch checked out elsewhere). `wt sw` only
  /// attaches an existing branch when an explicit `--path` is supplied
  /// (otherwise it dies with "branch exists without worktree"), so
  /// `makeCreateArguments` passes one. The branch's existing commits are
  /// preserved and the selected base ref is ignored. Fixes the "can't
  /// re-create a removed worktree under the same name" trap.
  var reuseExistingBranch: Bool = false
  /// Project setup script run as a tracked phase inside
  /// `createWorktreeStream` once the worktree exists (e.g. `npm
  /// install`). Sourced from `settings.projects[pid].git.createScript`.
  /// Runs in the newly-created worktree's directory, not `repoRoot`.
  /// Empty / whitespace-only / nil skips the setup phase entirely —
  /// the stream goes straight from `git worktree add` to `.finished`.
  /// A non-zero exit is best-effort: it never throws or rolls back the
  /// created worktree.
  var setupCommand: String?
}

/// Phases a `createWorktreeStream` run moves through. `creatingWorktree`
/// covers the `wt sw` (`git worktree add`) leg; `runningSetupScript`
/// covers the optional project setup command that runs afterward in the
/// new worktree's directory. Consumers track which phase a pending
/// creation is in to label progress.
nonisolated enum CreationPhase: Equatable, Sendable {
  case creatingWorktree
  case runningSetupScript
}

/// Stream events emitted while `wt sw` runs. Consumers render
/// `.progressLine` verbatim in the Create sheet's log area;
/// `.setupPhaseBegan` signals the run has finished `git worktree add`
/// and is now executing the project setup script in the new worktree;
/// `.finished` signals completion and carries the newly-created
/// worktree path.
nonisolated enum CreateWorktreeEvent: Equatable, Sendable {
  case progressLine(String)
  case setupPhaseBegan(worktreePath: URL)
  case finished(worktreePath: URL)
}

/// Typed errors surfaced by `GitWorktreeClient`. UI-visible cases
/// (`.uncommittedChanges`, `.branchExists`, `.invalidBranchName`, etc.)
/// drive tailored dialogs; `.commandFailed` is the catch-all that
/// round-trips the underlying git command + stderr.
nonisolated enum GitWorktreeError: Error, Equatable, Sendable {
  case executableMissing
  case branchExists(String)
  case invalidBranchName(String)
  case refNotFound(String)
  case fetchFailed(String)
  case uncommittedChanges(files: [String])
  case worktreeLocked(String)
  case commandFailed(command: String, stderr: String)
}

// MARK: - Client

/// Async-closures dependency covering the worktree-management spec's git
/// surface. Wraps the bundled `wt` script (for `ls --json`, streaming
/// create) plus a few complementary `/usr/bin/git` invocations (ref
/// queries, `worktree remove`, `worktree prune`, `fetch`). Closures run
/// off the main actor; callers `await` at call sites.
///
/// The live implementation is filled in by a later milestone; this type
/// scaffolds the shape so features and tests can link it now.
nonisolated struct GitWorktreeClient: Sendable {
  var lsWorktrees: @Sendable (_ repoRoot: URL) async throws -> [GitWtEntry]
  var localBranchNames: @Sendable (_ repoRoot: URL) async throws -> Set<String>
  var branchRefs: @Sendable (_ repoRoot: URL) async throws -> [String]
  var defaultRemoteBranchRef: @Sendable (_ repoRoot: URL) async throws -> String?
  var isValidBranchName: @Sendable (_ repoRoot: URL, _ name: String) async -> Bool

  var createWorktreeStream:
    @Sendable (_ spec: CreateWorktreeSpec)
      -> AsyncThrowingStream<CreateWorktreeEvent, Error>

  /// Removes a worktree using the relocate-then-prune strategy: the
  /// working directory is first moved into a per-process trash folder
  /// (atomic same-volume rename when possible), then `git worktree
  /// prune --expire=now` cleans up the metadata, with a `git worktree
  /// remove --force` fallback. Sidesteps git's submodule and uncommitted
  /// guards because once the working dir is gone, `prune` has no reason
  /// to refuse. The trash directory is rm-rf'd asynchronously so a
  /// large `.git` (e.g. submodule history) does not block the caller.
  var removeWorktree: @Sendable (_ repoRoot: URL, _ path: URL) async throws -> Void
  /// Best-effort `git branch -D <branch>` on the project's main repo —
  /// used to clean up the local branch left behind by `git worktree
  /// remove`, which intentionally keeps the ref so the user can recover
  /// it. Codans's UX is "delete the worktree means delete its
  /// branch too" (matches `wt rm`), so we drop it here. Never throws:
  /// git refuses if the branch is checked out elsewhere (main / shared
  /// branch), which must NOT fail the remove — that refusal is reported
  /// as `.kept` so the caller can surface why the branch lingered (and
  /// the next same-name create will reuse it via `reuseExistingBranch`).
  var deleteBranchIfExists: @Sendable (_ repoRoot: URL, _ branch: String) async -> BranchDeleteOutcome
  /// Best-effort `git push <remote> --delete <branch>` — deletes the remote
  /// tracking branch when the user opted into "Delete remote branch with
  /// worktree". The remote is resolved from the branch's configured upstream
  /// (`%(upstream:remotename)`), falling back to `origin`. MUST be called
  /// while the local branch still exists so the upstream config is readable;
  /// `removeWorktreeWithGit` invokes this before `deleteBranchIfExists`.
  /// Errors are swallowed: a missing remote ref, no upstream, or an offline
  /// network should never fail the local worktree removal.
  var deleteRemoteBranchIfExists: @Sendable (_ repoRoot: URL, _ branch: String) async -> Void
  var pruneWorktrees: @Sendable (_ repoRoot: URL) async throws -> Int

  var fetchRemote: @Sendable (_ repoRoot: URL, _ remote: String) async throws -> Void
  var changedFiles: @Sendable (_ worktreeRoot: URL) async throws -> [String]
}

// MARK: - Pure helpers (visible for tests)

nonisolated extension GitWorktreeClient {
  /// Derives a filesystem-safe relative directory path from a branch name.
  /// Preserves `/` as a path separator so a branch like `feature/abc`
  /// becomes nested directories `feature/abc` rather than `feature-abc`
  /// (HAN-57). Strips characters that break on macOS filesystems (`\0`,
  /// `:`, `\`); collapses repeated `/` and repeated `-` within each
  /// segment; trims leading/trailing dashes per segment; drops empty
  /// segments produced by leading, trailing, or repeated slashes.
  /// Intentionally conservative; a collision with an existing directory
  /// is a hard error at create time (W-Q5) rather than being silently
  /// suffixed.
  static func sanitizeBranchName(_ branch: String) -> String {
    var stripped = ""
    for ch in branch {
      switch ch {
      case "\0", ":", "\\":
        continue
      default:
        stripped.append(ch)
      }
    }
    let cleanedSegments: [String] =
      stripped
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(cleanSegment(_:))
      .filter { !$0.isEmpty }
    return cleanedSegments.joined(separator: "/")
  }

  /// Collapses consecutive `-` runs inside a single path segment and
  /// trims leading/trailing dashes. Returns "" when the segment is all
  /// dashes (callers drop the empty result so leading/trailing `/`
  /// produce no path component).
  private static func cleanSegment<S: StringProtocol>(_ segment: S) -> String {
    var collapsed = ""
    var lastWasDash = false
    for ch in segment {
      if ch == "-" {
        if !lastWasDash { collapsed.append(ch) }
        lastWasDash = true
      } else {
        collapsed.append(ch)
        lastWasDash = false
      }
    }
    while collapsed.first == "-" { collapsed.removeFirst() }
    while collapsed.last == "-" { collapsed.removeLast() }
    return collapsed
  }

  /// Constructs the `wt` argv for a streaming `sw` (switch-and-create)
  /// invocation. Argument order matters for the helper's own parsing.
  static func makeCreateArguments(for spec: CreateWorktreeSpec) -> [String] {
    var arguments = ["--base-dir", spec.baseDirectory.path(percentEncoded: false), "sw"]
    if spec.copyIgnored { arguments.append("--copy-ignored") }
    if spec.copyUntracked { arguments.append("--copy-untracked") }
    if !spec.baseRef.isEmpty {
      arguments.append("--from")
      arguments.append(spec.baseRef)
    }
    if spec.reuseExistingBranch {
      // Attach the pre-existing branch instead of creating it (`-b`).
      // The path mirrors git-wt's own default layout (`<base-dir>/<name>`)
      // so the resulting worktree lands exactly where a fresh create
      // would. git-wt ignores `--from` on this path.
      arguments.append("--path")
      arguments.append(
        spec.baseDirectory.appending(path: spec.name).path(percentEncoded: false)
      )
    }
    if spec.copyIgnored || spec.copyUntracked {
      arguments.append("--verbose")
    }
    arguments.append(spec.name)
    return arguments
  }

  /// Heuristic-maps `git worktree remove` stderr onto the typed error
  /// cases. Unknown patterns fall through to `.commandFailed`. Callers
  /// that need `.uncommittedChanges(files:)` populate `files` from
  /// `git status --porcelain` separately.
  ///
  /// All patterns are case-insensitive — git's message casing can vary
  /// with locale + version, and the `stderr.lowercased()` branches
  /// below matched case-insensitively long before the two regex
  /// branches did (issue #24 (b)). Inline `(?i)` keeps the original
  /// casing of the captured branch name so UI surfaces show what the
  /// user typed instead of a forced-lower version.
  static func mapGitStderr(command: String, stderr: String) -> GitWorktreeError {
    let lower = stderr.lowercased()
    if let match = stderr.firstMatch(of: /(?i)A branch named '([^']+)' already exists/) {
      return .branchExists(String(match.1))
    }
    if let match = stderr.firstMatch(of: /(?i)'([^']+)' is not a valid branch name/) {
      return .invalidBranchName(String(match.1))
    }
    if lower.contains("unknown revision") || lower.contains("bad revision") {
      return .refNotFound(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains("is locked") {
      return .worktreeLocked(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains("contains modified or untracked files") {
      return .uncommittedChanges(files: [])
    }
    return .commandFailed(
      command: command,
      stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// True when `git worktree remove` stderr signals the path is already
  /// not a registered worktree — git's "is not a working tree" refusal.
  /// The Remove flow treats this as success: an orphaned catalog node
  /// whose backing directory and worktree registration are both already
  /// gone (e.g. a stale path left by an out-of-band cleanup, or a node
  /// cross-wired to a directory that no longer exists) has nothing left
  /// for git to remove. Surfacing a fatal `.commandFailed` here would
  /// wedge the node permanently — the user can never clear it because
  /// the very command meant to clear it refuses. Removal is idempotent:
  /// the desired end-state (no such worktree) is met, so we report
  /// success and let the caller drop the catalog node.
  static func stderrIndicatesAlreadyRemoved(_ stderr: String) -> Bool {
    stderr.lowercased().contains("is not a working tree")
  }

  /// Identifies the created worktree path by diffing `wt ls --json`
  /// snapshots taken immediately before and after `wt sw`. Returns
  /// the single new entry's path; falls back to matching
  /// `fallbackStdoutLast` (the legacy last-line heuristic) when the
  /// diff is ambiguous, and nil when the diff is empty. Pure — all
  /// decisions flow from the arguments so the unit tests don't need a
  /// live git.
  ///
  /// Paths are compared via `URL.standardizedFileURL.path` so a
  /// trailing slash or `.` component difference between `wt sw`'s
  /// echo and `wt ls`'s canonicalized JSON doesn't produce a false
  /// mismatch. Issue #24 (c).
  static func pickNewWorktreePath(
    preEntries: [GitWtEntry],
    postEntries: [GitWtEntry],
    fallbackStdoutLast: String
  ) -> URL? {
    // Local canonical helper — deliberately does NOT go through
    // `HierarchyManager.canonicalPath` / `resolvingSymlinksInPath`.
    // Both inputs here come from `wt ls --json` on the same repo in
    // the same process, so they share a string form; plain
    // `standardizedFileURL` (trailing-slash + `.`/`..` normalization)
    // gives a stable diff without caring about symlink state.
    //
    // Do NOT "fix" this to match HierarchyManager.canonicalPath —
    // that would make pickNewWorktreePath wrong any time the symlink
    // table shifts between `wt ls` invocations (e.g. a concurrent
    // user-space symlink edit) because the pre/post strings would
    // resolve differently even though `wt` emitted the identical
    // raw form. The two canonical layers are intentional:
    // `HierarchyManager.canonicalPath` reconciles T-WORKTREE's wt
    // output against T-PROJECT's resolved rootPath; this helper
    // reconciles wt-against-itself. Issue #24 (c) follow-up F1.
    func canonical(_ path: String) -> String {
      URL(fileURLWithPath: path).standardizedFileURL.path
    }
    let prePaths = Set(preEntries.map { canonical($0.path) })
    let newEntries = postEntries.filter { !prePaths.contains(canonical($0.path)) }
    if newEntries.count == 1 {
      return URL(fileURLWithPath: newEntries[0].path).standardizedFileURL
    }
    if newEntries.isEmpty {
      // wt claimed success but ls still doesn't see a new entry —
      // caller will surface .commandFailed so the sheet reports
      // something rather than yielding a ghost path.
      return nil
    }
    // Multiple new entries — disambiguate via the legacy
    // last-non-empty-stdout heuristic. This is the belt-and-braces
    // path the plan calls out: if upstream `wt` ever prints a
    // reliable worktree path as its last stdout line, we still
    // honour it; if not, we fall through to the first entry and
    // let the caller log a warning.
    let fallbackTrimmed = fallbackStdoutLast.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallbackTrimmed.isEmpty {
      let fallbackCanonical = canonical(fallbackTrimmed)
      if let match = newEntries.first(where: { canonical($0.path) == fallbackCanonical }) {
        return URL(fileURLWithPath: match.path).standardizedFileURL
      }
    }
    return URL(fileURLWithPath: newEntries[0].path).standardizedFileURL
  }

  /// Parses `git status --porcelain` output into a list of file paths.
  /// Strips the two-character status prefix (XY) plus the following space.
  /// Index arithmetic is byte-safe: we drop a fixed three-byte prefix from
  /// the UTF-8 view rather than stepping `String.Index` to avoid any
  /// surprises with composed characters in file names.
  static func parsePorcelainPaths(_ output: String) -> [String] {
    var paths: [String] = []
    for rawLine in output.components(separatedBy: "\n") {
      guard rawLine.utf8.count >= 4 else { continue }
      let utf8 = rawLine.utf8
      let start = utf8.index(utf8.startIndex, offsetBy: 3)
      guard let trimmed = String(utf8[start...])?.trimmingCharacters(in: .whitespaces),
        !trimmed.isEmpty
      else { continue }
      paths.append(trimmed)
    }
    return paths
  }
}

// MARK: - Live implementation helpers

/// Thread-safe box holding the spawned `wt` Process so a cancellation
/// path on a different thread (`AsyncThrowingStream.onTermination`
/// is not isolated to any particular actor) can terminate it without
/// racing the Task body that assigned it. `@unchecked Sendable`
/// because the NSLock discipline is what actually enforces safety.
/// Issue #24 (a).
nonisolated final class CreateWorktreeProcessBox: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?

  func set(_ p: Process) {
    lock.lock()
    process = p
    lock.unlock()
  }

  func terminateIfRunning() {
    lock.lock()
    let captured = process
    lock.unlock()
    guard let captured, captured.isRunning else { return }
    captured.terminate()
  }
}

/// Resolves the bundled `wt` script out of the app bundle's Resources
/// folder. Debug and Release builds alike embed the script via Tuist's
/// post-build `embed-git-wt.sh` (see `apps/mac/scripts/`).
nonisolated func wtScriptURL() throws -> URL {
  guard
    let url = Bundle.main.url(
      forResource: "wt", withExtension: nil, subdirectory: "git-wt"
    )
  else {
    throw GitWorktreeError.executableMissing
  }
  return url
}

/// Shell-out primitives used by `GitWorktreeClient.makeLive`. Kept at
/// file scope rather than as struct statics so tests can mock them per
/// closure if needed — unused by default because the M13 integration
/// test exercises the real live implementation.
nonisolated enum GitWorktreeShell {
  static let runner = FoundationCommandRunner()
  static let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  /// 60 s covers the slowest non-copy git operation we issue. Streaming
  /// `wt sw` bypasses this limit by using its own pipe-driven runner.
  static let defaultTimeout: Duration = .seconds(60)
  static let maxOutputBytes = 4 * 1024 * 1024

  /// One-shot invocation returning captured stdout/stderr.
  static func run(
    executable: URL, arguments: [String], cwd: URL
  ) async -> CommandOutcome {
    await runner.run(
      executable: executable,
      arguments: arguments,
      env: ProcessInfo.processInfo.environment,
      cwd: cwd,
      timeout: defaultTimeout,
      maxOutputBytes: maxOutputBytes
    )
  }

  /// Decodes stdout bytes to UTF-8, returning `""` on decode failure so
  /// the caller gets a deterministic empty result rather than a throw.
  static func decodeUTF8(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
  }

  /// Low-level streaming runner for `wt sw` — spawns a `Process`, wires
  /// per-line stdout/stderr handlers, and yields line-level events until
  /// the child exits. On success the final event is
  /// `.exited(code, stderr)`.
  ///
  /// The optional `onSpawn` callback fires immediately before
  /// `process.run()` so the caller can capture the `Process` reference
  /// for external cancellation (see `createWorktreeStream`'s
  /// `continuation.onTermination` wiring — issue #24 (a)). Default
  /// is a no-op so existing callers stay source-compatible.
  static func runStream(
    executable: URL,
    arguments: [String],
    cwd: URL,
    onSpawn: @Sendable (Process) -> Void = { _ in },
    onStdout: @escaping @Sendable (String) -> Void,
    onStderr: @escaping @Sendable (String) -> Void
  ) async -> (exitCode: Int32, stdoutLast: String, stderrCollected: String, spawnFailedReason: String?) {
    await withCheckedContinuation { cont in
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.currentDirectoryURL = cwd
      process.environment = ProcessInfo.processInfo.environment
      process.standardInput = FileHandle.nullDevice

      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe

      // Box mutable line buffers so the Sendable readability handlers can
      // accumulate partial lines across reads without data races.
      final class LineBuffer: @unchecked Sendable {
        var buffer = ""
        var lastNonEmpty = ""
      }
      let stdoutState = LineBuffer()
      let stderrState = LineBuffer()
      let stdoutLock = NSLock()
      let stderrLock = NSLock()

      stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) else { return }
        stdoutLock.lock()
        stdoutState.buffer += str
        var lines: [String] = []
        while let nl = stdoutState.buffer.firstIndex(of: "\n") {
          let line = String(stdoutState.buffer[..<nl])
          stdoutState.buffer.removeSubrange(...nl)
          lines.append(line)
        }
        for line in lines {
          let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { stdoutState.lastNonEmpty = trimmed }
        }
        stdoutLock.unlock()
        for line in lines { onStdout(line) }
      }
      stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) else { return }
        stderrLock.lock()
        stderrState.buffer += str
        var lines: [String] = []
        while let nl = stderrState.buffer.firstIndex(of: "\n") {
          let line = String(stderrState.buffer[..<nl])
          stderrState.buffer.removeSubrange(...nl)
          lines.append(line)
        }
        stderrLock.unlock()
        for line in lines { onStderr(line) }
      }

      process.terminationHandler = { proc in
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain any trailing bytes that did not end in a newline.
        let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailOut.isEmpty, let str = String(data: tailOut, encoding: .utf8) {
          stdoutLock.lock()
          let combined = stdoutState.buffer + str
          stdoutState.buffer = ""
          let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { stdoutState.lastNonEmpty = trimmed }
          stdoutLock.unlock()
          onStdout(combined)
        }
        let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !tailErr.isEmpty, let str = String(data: tailErr, encoding: .utf8) {
          stderrLock.lock()
          stderrState.buffer += str
          stderrLock.unlock()
          onStderr(str)
        }
        stdoutLock.lock()
        let finalLastNonEmpty = stdoutState.lastNonEmpty
        stdoutLock.unlock()
        stderrLock.lock()
        let finalStderr = stderrState.buffer
        stderrLock.unlock()
        cont.resume(
          returning: (
            exitCode: proc.terminationStatus,
            stdoutLast: finalLastNonEmpty,
            stderrCollected: finalStderr,
            spawnFailedReason: nil
          ))
      }

      // Hand the Process to the caller before run() so a
      // cancellation path can hold a reference before the child
      // actually starts.
      onSpawn(process)

      do {
        try process.run()
      } catch {
        cont.resume(
          returning: (
            exitCode: -1,
            stdoutLast: "",
            stderrCollected: "",
            spawnFailedReason: error.localizedDescription
          ))
      }
    }
  }
}

nonisolated extension GitWorktreeClient {
  // Binds every closure to a live `wt`/`git` invocation. Used from
  // `CodansApp.bringUp()` at startup.
  //
  // `onCreateWorktreeSpawn` is an optional testing seam — the live
  // `createWorktreeStream` path calls it immediately before
  // `process.run()`. It can fire up to TWICE per creation: first with
  // the `git worktree add` (`wt`) child, then — when the spec carries a
  // non-empty `setupCommand` — again with the setup `bash` child.
  // Consumers that capture "the spawned process" must therefore expect
  // the LATEST spawn to win (a later `set(_:)` overwrites the earlier
  // one). Production code leaves it nil; integration tests pass a closure
  // that captures a weak reference to the Process so they can assert
  // `!process.isRunning` after cancelling the stream (issue #24 (a)).
  //
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func makeLive(
    onCreateWorktreeSpawn: (@Sendable (Process) -> Void)? = nil
  ) -> GitWorktreeClient {
    GitWorktreeClient(
      lsWorktrees: { repoRoot in
        let wt = try wtScriptURL()
        let outcome = await GitWorktreeShell.run(
          executable: wt, arguments: ["ls", "--json"], cwd: repoRoot
        )
        switch outcome {
        case .exited(let code, let stdout, let stderr, _):
          guard code == 0 else {
            throw GitWorktreeError.commandFailed(
              command: "wt ls --json",
              stderr: GitWorktreeShell.decodeUTF8(stderr)
            )
          }
          let trimmed = GitWorktreeShell.decodeUTF8(stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return [] }
          let entries = try JSONDecoder().decode([GitWtEntry].self, from: Data(trimmed.utf8))
          return entries.filter { !$0.isBare }
        case .timedOut:
          throw GitWorktreeError.commandFailed(command: "wt ls --json", stderr: "timed out")
        case .spawnFailed(let reason):
          throw GitWorktreeError.commandFailed(command: "wt ls --json", stderr: reason)
        }
      },

      localBranchNames: { repoRoot in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "for-each-ref", "--format=%(refname:short)", "refs/heads",
          ],
          cwd: repoRoot
        )
        let stdout = try extractStdout(outcome, command: "git for-each-ref refs/heads")
        return Set(
          stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        )
      },

      branchRefs: { repoRoot in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes",
          ],
          cwd: repoRoot
        )
        let stdout = try extractStdout(outcome, command: "git for-each-ref refs/heads refs/remotes")
        return
          stdout
          .components(separatedBy: "\n")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty && !$0.hasSuffix("/HEAD") }
      },

      defaultRemoteBranchRef: { repoRoot in
        // Try symbolic-ref first (fast; succeeds when `origin/HEAD` is set locally).
        let symbolic = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
          ],
          cwd: repoRoot
        )
        if case .exited(let code, let data, _, _) = symbolic, code == 0 {
          let trimmed = GitWorktreeShell.decodeUTF8(data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { return trimmed }
        }
        // Fallback: parse `git remote show origin` for "HEAD branch: X".
        let show = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "remote", "show", "origin",
          ],
          cwd: repoRoot
        )
        if case .exited(let code, let data, _, _) = show, code == 0 {
          let text = GitWorktreeShell.decodeUTF8(data)
          for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("HEAD branch:") {
              let branch =
                trimmed
                .dropFirst("HEAD branch:".count)
                .trimmingCharacters(in: .whitespaces)
              if !branch.isEmpty && branch != "(unknown)" {
                return "origin/\(branch)"
              }
            }
          }
        }
        return nil
      },

      isValidBranchName: { repoRoot, name in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "check-ref-format", "--branch", name,
          ],
          cwd: repoRoot
        )
        if case .exited(let code, _, _, _) = outcome, code == 0 {
          return true
        }
        return false
      },

      createWorktreeStream: { spec in
        AsyncThrowingStream { continuation in
          // Locked box so `continuation.onTermination` (fires on any
          // thread / isolation context) can safely read the Process
          // reference and terminate the child. Without this, a
          // cancelled consumer leaks the `wt` child until it finishes
          // on its own — see issue #24 (a).
          let processBox = CreateWorktreeProcessBox()

          let task = Task {
            do {
              let wt = try wtScriptURL()
              // Optional pre-fetch.
              if spec.fetchOrigin {
                let fetch = await GitWorktreeShell.run(
                  executable: GitWorktreeShell.gitURL,
                  arguments: [
                    "-C", spec.repoRoot.path(percentEncoded: false),
                    "fetch", "origin",
                  ],
                  cwd: spec.repoRoot
                )
                if case .exited(let code, _, let err, _) = fetch, code != 0 {
                  continuation.finish(
                    throwing: GitWorktreeError.fetchFailed(
                      GitWorktreeShell.decodeUTF8(err)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                  return
                }
              }

              // Snapshot the live worktree set BEFORE spawning `wt sw`.
              // After exit we diff against this to identify the new
              // entry — more robust than treating wt's last-non-empty
              // stdout line as the path (issue #24 (c)). Best-effort:
              // if wt ls fails for any reason, we fall through with an
              // empty snapshot and the diff will surface every
              // post-create entry; the fallbackStdoutLast path then
              // picks the right one.
              let preEntries = await liveLsEntries(wt: wt, repoRoot: spec.repoRoot)

              let args = makeCreateArguments(for: spec)
              let outcome = await GitWorktreeShell.runStream(
                executable: wt,
                arguments: args,
                cwd: spec.repoRoot,
                onSpawn: { process in
                  processBox.set(process)
                  onCreateWorktreeSpawn?(process)
                },
                onStdout: { line in continuation.yield(.progressLine(line)) },
                onStderr: { line in continuation.yield(.progressLine(line)) }
              )
              if let reason = outcome.spawnFailedReason {
                continuation.finish(
                  throwing: GitWorktreeError.commandFailed(
                    command: "wt \(args.joined(separator: " "))",
                    stderr: reason
                  ))
                return
              }
              guard outcome.exitCode == 0 else {
                let command = "wt \(args.joined(separator: " "))"
                continuation.finish(
                  throwing: mapGitStderr(
                    command: command,
                    stderr: outcome.stderrCollected
                  ))
                return
              }

              // Post-snapshot + diff. We don't require stdoutLast to
              // be non-empty anymore — it's a tiebreaker, not the
              // primary source.
              let postEntries = await liveLsEntries(wt: wt, repoRoot: spec.repoRoot)
              guard
                let worktreeURL = pickNewWorktreePath(
                  preEntries: preEntries,
                  postEntries: postEntries,
                  fallbackStdoutLast: outcome.stdoutLast
                )
              else {
                continuation.finish(
                  throwing: GitWorktreeError.commandFailed(
                    command: "wt \(args.joined(separator: " "))",
                    stderr: "wt exited 0 but no new worktree appeared in wt ls"
                  ))
                return
              }

              // Optional setup-script phase. Runs as a tracked phase
              // INSIDE the stream (rather than later as the first pane's
              // initial command) so a cancelled creation also kills the
              // setup child — it reuses the SAME `processBox` +
              // `continuation.onTermination` wiring the `wt sw`
              // invocation uses. The command runs in the freshly-created
              // worktree (`worktreeURL`), not `spec.repoRoot`.
              let setup = spec.setupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
              if let setup, !setup.isEmpty {
                continuation.yield(.setupPhaseBegan(worktreePath: worktreeURL))
                let setupOutcome = await GitWorktreeShell.runStream(
                  executable: URL(fileURLWithPath: "/bin/bash"),
                  arguments: ["-lc", setup],
                  cwd: worktreeURL,
                  onSpawn: { process in
                    processBox.set(process)
                    onCreateWorktreeSpawn?(process)
                  },
                  onStdout: { line in continuation.yield(.progressLine(line)) },
                  onStderr: { line in continuation.yield(.progressLine(line)) }
                )
                // Best-effort: a spawn failure or non-zero exit from the
                // setup script must NOT throw or roll back the worktree.
                // We note it as a final progress line and still finish.
                if let reason = setupOutcome.spawnFailedReason {
                  continuation.yield(
                    .progressLine("setup script failed to start: \(reason)"))
                } else if setupOutcome.exitCode != 0 {
                  continuation.yield(
                    .progressLine("setup script exited with code \(setupOutcome.exitCode)"))
                }
              }

              continuation.yield(.finished(worktreePath: worktreeURL))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
          continuation.onTermination = { _ in
            // Order matters: terminate the child FIRST so
            // `runStream`'s terminationHandler fires and resumes its
            // continuation naturally (Task body completes, reaches
            // the final `continuation.finish(...)`). Cancelling the
            // Task first would still leave the wt child alive until
            // it finished, defeating the point of this handler.
            // Issue #24 (a).
            processBox.terminateIfRunning()
            task.cancel()
          }
        }
      },

      removeWorktree: { repoRoot, path in
        // Strategy:
        // 1) Try to relocate the worktree directory to a trash folder so
        //    the UI sees it disappear immediately and `git worktree
        //    prune` can clean the metadata without tripping over git's
        //    submodule or "modified files" refusals.
        // 2) If relocate succeeded, run `prune --expire=now`. The working
        //    directory is already gone, so removal has MATERIALLY
        //    succeeded — any further git cleanup is best-effort and must
        //    never throw. If prune fails we still try `remove --force` as
        //    a cleanup pass, but swallow its outcome.
        // 3) If relocate failed (path missing, cross-volume, ENOPERM),
        //    `remove --force <originalPath>` is the REAL removal, so its
        //    failure is fatal — except the idempotent "is not a working
        //    tree" case, which `forceRemoveWorktree` already maps to
        //    success.
        // 4) Schedule async rm-rf of the relocated dir so a large `.git`
        //    (submodule history) does not block the caller.
        //
        // The post-relocate "best-effort, never throw" rule is load-
        // bearing: a throw here aborts the caller before it drops the
        // catalog row, stranding an orphaned node whose backing directory
        // no longer exists. That is exactly how an in-app Remove on a
        // branch-switched, pinned worktree left a row that could never be
        // deleted again (`remove --force` against the emptied path keeps
        // failing with "is not a working tree").
        let relocated = relocateWorktreeForRemoval(path)
        if let relocated {
          scheduleTrashCleanup(relocated)
          let pruneOutcome = await GitWorktreeShell.run(
            executable: GitWorktreeShell.gitURL,
            arguments: [
              "-C", repoRoot.path(percentEncoded: false),
              "worktree", "prune", "--expire=now",
            ],
            cwd: repoRoot
          )
          if case .exited(let code, _, _, _) = pruneOutcome, code == 0 {
            return
          }
          // Prune failed — try a forced remove as cleanup, but the dir is
          // already relocated so removal is done regardless of the result.
          try? await forceRemoveWorktree(repoRoot: repoRoot, path: path)
          return
        }
        // Relocate failed: the directory is still in place, so the forced
        // remove is the actual removal and its failure is fatal.
        try await forceRemoveWorktree(repoRoot: repoRoot, path: path)
      },

      deleteBranchIfExists: { repoRoot, branch in
        // Best-effort: git refuses if the branch is checked out by
        // another worktree (e.g. it's the project's main branch) — that
        // refusal is exactly when we must NOT delete it, so we report
        // `.kept` instead of failing the remove flow. A genuinely-absent
        // branch is `.absent`. Neither aborts the caller.
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "branch", "-D", branch,
          ],
          cwd: repoRoot
        )
        guard case .exited(let code, _, let stderr, _) = outcome else {
          return .kept(reason: "git branch -D did not complete")
        }
        if code == 0 { return .deleted }
        let message = GitWorktreeShell.decodeUTF8(stderr)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        // git's "not found" phrasings vary by version/locale; treat any
        // of them as already-gone rather than a kept branch.
        if lower.contains("not found") || lower.contains("no branch named")
          || lower.contains("couldn't look up")
        {
          return .absent
        }
        return .kept(reason: message.isEmpty ? "git refused to delete the branch" : message)
      },

      deleteRemoteBranchIfExists: { repoRoot, branch in
        // Resolve the remote this branch tracks. Read it from the local
        // branch's upstream config while the branch still exists; fall back
        // to "origin" when there is no configured upstream.
        let remoteOutcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "for-each-ref", "--format=%(upstream:remotename)",
            "refs/heads/\(branch)",
          ],
          cwd: repoRoot
        )
        var remote = "origin"
        if case .exited(let code, let data, _, _) = remoteOutcome, code == 0 {
          let trimmed = GitWorktreeShell.decodeUTF8(data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { remote = trimmed }
        }
        // Best-effort: git fails if the remote ref is already gone or the
        // network is unreachable — neither should fail the worktree remove.
        _ = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "push", remote, "--delete", branch,
          ],
          cwd: repoRoot
        )
      },

      pruneWorktrees: { repoRoot in
        // Diff lsWorktrees before/after so the caller can surface an accurate
        // toast. `git worktree prune` itself prints nothing on success.
        let wt = try wtScriptURL()
        let before = await liveLsCount(wt: wt, repoRoot: repoRoot)
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "worktree", "prune",
          ],
          cwd: repoRoot
        )
        _ = try extractStdout(outcome, command: "git worktree prune")
        let after = await liveLsCount(wt: wt, repoRoot: repoRoot)
        return max(0, before - after)
      },

      fetchRemote: { repoRoot, remote in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", repoRoot.path(percentEncoded: false),
            "fetch", remote,
          ],
          cwd: repoRoot
        )
        switch outcome {
        case .exited(let code, _, _, _) where code == 0:
          return
        case .exited(_, _, let stderrData, _):
          throw GitWorktreeError.fetchFailed(
            GitWorktreeShell.decodeUTF8(stderrData)
              .trimmingCharacters(in: .whitespacesAndNewlines)
          )
        case .timedOut:
          throw GitWorktreeError.fetchFailed("timed out")
        case .spawnFailed(let reason):
          throw GitWorktreeError.fetchFailed(reason)
        }
      },

      changedFiles: { worktreeRoot in
        let outcome = await GitWorktreeShell.run(
          executable: GitWorktreeShell.gitURL,
          arguments: [
            "-C", worktreeRoot.path(percentEncoded: false),
            "status", "--porcelain",
          ],
          cwd: worktreeRoot
        )
        let stdout = try extractStdout(outcome, command: "git status --porcelain")
        return parsePorcelainPaths(stdout)
      }
    )
  }

  /// Best-effort `wt ls --json` → `[GitWtEntry]`. Returns `[]` on any
  /// failure — used by `createWorktreeStream` for the diff-based
  /// path-picking (issue #24 (c)) and by `pruneWorktrees` for its
  /// before/after count. Both callers tolerate empty on error.
  fileprivate static func liveLsEntries(wt: URL, repoRoot: URL) async -> [GitWtEntry] {
    let outcome = await GitWorktreeShell.run(
      executable: wt, arguments: ["ls", "--json"], cwd: repoRoot
    )
    guard case .exited(let code, let data, _, _) = outcome, code == 0 else { return [] }
    let text = GitWorktreeShell.decodeUTF8(data).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
      let entries = try? JSONDecoder().decode([GitWtEntry].self, from: Data(text.utf8))
    else { return [] }
    return entries.filter { !$0.isBare }
  }

  /// Helper for `pruneWorktrees` — best-effort count of non-bare entries
  /// from `wt ls --json`; returns 0 on any failure so the caller's diff
  /// degrades to reporting zero pruned instead of throwing.
  fileprivate static func liveLsCount(wt: URL, repoRoot: URL) async -> Int {
    await liveLsEntries(wt: wt, repoRoot: repoRoot).count
  }

  /// Moves the worktree directory into a per-process trash folder so
  /// the on-disk working tree disappears immediately. Returns the new
  /// location on success, or `nil` if the source does not exist or
  /// every candidate trash base failed (e.g. cross-volume rename).
  /// Trying `/tmp` first then `NSTemporaryDirectory()` covers the
  /// common case of `/tmp` being on the same volume as the worktree
  /// while still falling back to a writable per-user temp on locked-
  /// down systems.
  fileprivate static func relocateWorktreeForRemoval(_ worktreeURL: URL) -> URL? {
    let fileManager = FileManager.default
    let worktreePath = worktreeURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: worktreePath) else { return nil }
    let candidates: [URL] = [
      URL(filePath: "/tmp", directoryHint: .isDirectory),
      fileManager.temporaryDirectory,
    ]
    for base in candidates {
      let trashBase = base.appending(
        path: "codans-worktree-trash", directoryHint: .isDirectory
      )
      do {
        try fileManager.createDirectory(at: trashBase, withIntermediateDirectories: true)
      } catch {
        continue
      }
      let destination = trashBase.appending(
        path: "\(worktreeURL.lastPathComponent)-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      do {
        try fileManager.moveItem(at: worktreeURL, to: destination)
        return destination
      } catch {
        continue
      }
    }
    return nil
  }

  /// Detached `rm -rf` of the relocated worktree directory. Submodule
  /// worktrees can carry hundreds of MB of `.git/modules/...` history
  /// per submodule; running this synchronously would stall the Remove
  /// confirmation for visible time. Failures are swallowed — the
  /// trash directory is namespaced under a UUID so a leaked entry
  /// doesn't collide with future removals.
  fileprivate static func scheduleTrashCleanup(_ url: URL) {
    Task.detached(priority: .utility) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// `git worktree remove --force` against the original path. Used as
  /// the second leg of the relocate-then-prune strategy when prune
  /// fails (rare; e.g. corrupted gitfile) and as the only leg when the
  /// directory could not be relocated. Errors round-trip through
  /// `mapGitStderr` so the caller can surface a typed error.
  fileprivate static func forceRemoveWorktree(repoRoot: URL, path: URL) async throws {
    let args = [
      "-C", repoRoot.path(percentEncoded: false),
      "worktree", "remove", "--force",
      path.path(percentEncoded: false),
    ]
    let outcome = await GitWorktreeShell.run(
      executable: GitWorktreeShell.gitURL, arguments: args, cwd: repoRoot
    )
    switch outcome {
    case .exited(let code, _, _, _) where code == 0:
      return
    case .exited(_, _, let stderr, _):
      let decoded = GitWorktreeShell.decodeUTF8(stderr)
      // Idempotent Remove: git already doesn't see this path as a
      // worktree, so the removal goal is satisfied. Returning success
      // lets the caller drop the (possibly orphaned) catalog node
      // instead of trapping it behind a fatal error.
      if stderrIndicatesAlreadyRemoved(decoded) {
        return
      }
      throw mapGitStderr(
        command: "git " + args.joined(separator: " "),
        stderr: decoded
      )
    case .timedOut:
      throw GitWorktreeError.commandFailed(
        command: "git " + args.joined(separator: " "), stderr: "timed out"
      )
    case .spawnFailed(let reason):
      throw GitWorktreeError.commandFailed(
        command: "git " + args.joined(separator: " "), stderr: reason
      )
    }
  }

  /// Unwraps a `CommandOutcome`'s successful stdout or throws a mapped
  /// `GitWorktreeError`. Used by the live closures for one-shot git
  /// calls that don't need specialized error handling.
  fileprivate static func extractStdout(_ outcome: CommandOutcome, command: String) throws -> String {
    switch outcome {
    case .exited(let code, let stdout, let stderr, _):
      guard code == 0 else {
        throw mapGitStderr(command: command, stderr: GitWorktreeShell.decodeUTF8(stderr))
      }
      return GitWorktreeShell.decodeUTF8(stdout)
    case .timedOut:
      throw GitWorktreeError.commandFailed(command: command, stderr: "timed out")
    case .spawnFailed(let reason):
      throw GitWorktreeError.commandFailed(command: command, stderr: reason)
    }
  }
}

// MARK: - DependencyKey

extension GitWorktreeClient: DependencyKey {
  /// Live value — bound to `makeLive()` which uses the bundled `wt`
  /// script and `/usr/bin/git`. Closures throw
  /// `GitWorktreeError.executableMissing` if the `wt` resource cannot
  /// be resolved (which the pre-build `verify-git-wt.sh` makes
  /// impossible in a clean build).
  static let liveValue: GitWorktreeClient = .makeLive()

  static let testValue: GitWorktreeClient = GitWorktreeClient(
    lsWorktrees: unimplemented("GitWorktreeClient.lsWorktrees", placeholder: []),
    localBranchNames: unimplemented("GitWorktreeClient.localBranchNames", placeholder: []),
    branchRefs: unimplemented("GitWorktreeClient.branchRefs", placeholder: []),
    defaultRemoteBranchRef: unimplemented("GitWorktreeClient.defaultRemoteBranchRef", placeholder: nil),
    isValidBranchName: unimplemented("GitWorktreeClient.isValidBranchName", placeholder: false),
    createWorktreeStream: { _ in
      AsyncThrowingStream { $0.finish() }
    },
    removeWorktree: unimplemented("GitWorktreeClient.removeWorktree"),
    deleteBranchIfExists: { _, _ in .absent },
    deleteRemoteBranchIfExists: { _, _ in },
    pruneWorktrees: unimplemented("GitWorktreeClient.pruneWorktrees", placeholder: 0),
    fetchRemote: unimplemented("GitWorktreeClient.fetchRemote"),
    changedFiles: unimplemented("GitWorktreeClient.changedFiles", placeholder: [])
  )
}

extension DependencyValues {
  var gitWorktreeClient: GitWorktreeClient {
    get { self[GitWorktreeClient.self] }
    set { self[GitWorktreeClient.self] = newValue }
  }
}
