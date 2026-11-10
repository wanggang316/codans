import Foundation

/// Shared subprocess primitive used by any in-app module that shells out — `codans/Git/`
/// for `git`, `codans/GitHub/` for `gh`, and so on. The live implementation wraps
/// `Foundation.Process`; tests inject `RecordingCommandRunner` to exercise timeout /
/// output-cap / non-zero-exit paths without a real child process.
///
/// The runner intentionally does not know about any domain error type — it reports a
/// mechanical `CommandOutcome`, and each caller translates that into its own richer error
/// (`GitError`, `GitPlatformError`, …).
nonisolated protocol CommandRunner: Sendable {
  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int,
    launch: CommandLaunch
  ) async -> CommandOutcome
}

extension CommandRunner {
  /// Starts `executable` directly (`.direct`).
  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int
  ) async -> CommandOutcome {
    await run(
      executable: executable, arguments: arguments, env: env, cwd: cwd,
      timeout: timeout, maxOutputBytes: maxOutputBytes, launch: .direct)
  }
}

/// How the runner starts a command. See `docs/design-docs/environment.md`.
nonisolated enum CommandLaunch: Equatable, Sendable {
  /// Start the executable with exactly `env`. For `ssh` (the remote login
  /// shell sets the environment), bundled internal binaries, and commands
  /// that start their own shell.
  case direct
  /// Start it through the user's login shell (`LoginShellLaunch`), so the
  /// command and what it starts get the login `PATH`. Each run pays for the
  /// user's rc. For git that reaches a remote (it may start credential, LFS,
  /// or ssh helpers), `gh`, and `glab`.
  case loginShell
  /// Start it directly; run it once more through the login shell only when
  /// the direct run reports a missing command (`LoginShellLaunch.reportsMissingCommand`).
  /// For local git and the bundled `wt`, which run often and rarely need the
  /// user's `PATH`.
  case directThenLoginShell

  /// One entry per attempt, in order: `true` when that attempt goes through
  /// the login shell. A later attempt runs only when the one before it
  /// reported a missing command.
  var attemptsViaLoginShell: [Bool] {
    switch self {
    case .direct: [false]
    case .loginShell: [true]
    case .directThenLoginShell: [false, true]
    }
  }
}

nonisolated enum CommandOutcome: Equatable, Sendable {
  /// Child exited within the timeout. `stdout`/`stderr` captured up to the cap; `stdoutOverflow`
  /// is `true` iff the stdout cap was hit (bytes past the cap are discarded).
  case exited(code: Int32, stdout: Data, stderr: Data, stdoutOverflow: Bool)
  /// Child was still running at the deadline. The runner sent SIGTERM then SIGKILL. `stdout`
  /// reflects whatever was drained before the kill.
  case timedOut
  /// `process.run()` threw; typically ENOENT or a permission problem. `reason` is the
  /// localized description.
  case spawnFailed(reason: String)
}

/// Bounds how many child processes launch concurrently across all callers.
/// A shared async counting semaphore: `acquire()` suspends once the limit is
/// reached, and `release()` hands a freed slot directly to the oldest waiter
/// (FIFO) so the in-flight count never exceeds `limit`.
private actor SubprocessGate {
  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) { self.limit = limit }

  func acquire() async {
    if active < limit {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      active -= 1
    } else {
      // Transfer the slot to the next waiter; `active` stays at the limit.
      waiters.removeFirst().resume()
    }
  }
}

/// Live implementation. Correctness-critical points:
///
/// - `terminationHandler` is installed **synchronously** before `process.run()`, so an exit
///   that lands between `run()` returning and our await arriving still resumes our
///   continuation. Previously a `Task.detached { withCheckedContinuation { … } }` introduced
///   a race window.
/// - Output is read by `PipeCollector` through dispatch sources, so no thread blocks in
///   `read`. After the child exits, reading stops at EOF or after `eofGrace`: a process
///   forked elsewhere in the app can hold a write end and keep EOF from ever arriving.
nonisolated struct FoundationCommandRunner: CommandRunner {
  /// Caps concurrent child-process launches across every caller. Foundation's
  /// `Process` / `Pipe` machinery races under heavy concurrent spawning, and
  /// the launch-time git status/diff fan-out across many worktrees can
  /// otherwise spawn dozens at once — which intermittently corrupted the heap
  /// (an `EXC_BAD_ACCESS` that surfaced later in unrelated task allocation).
  /// A modest cap keeps the fan-out fast while staying clear of that contention.
  private static let gate = SubprocessGate(limit: 6)

  /// How long to keep reading output after the child exits.
  var eofGrace: Duration = PipeCollector.defaultGrace

  /// The shell for `.loginShell` launches; `nil` reads the user's login shell
  /// on every run.
  var loginShell: LoginShell?

  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int,
    launch mode: CommandLaunch
  ) async -> CommandOutcome {
    // `Process.currentDirectoryURL` raises an Objective-C exception for a
    // non-file URL (a Remote Project's `codans-host://` location). Return an
    // error instead: a location that reaches this runner unresolved is a
    // routing bug, not a reason to stop the app.
    guard cwd.isFileURL else { return .spawnFailed(reason: Self.nonLocalDirectoryReason(cwd)) }
    var outcome = CommandOutcome.spawnFailed(reason: "no launch")
    for viaLoginShell in mode.attemptsViaLoginShell {
      let launch: ProcessLaunch
      do {
        launch = try ProcessLaunch.make(
          executable: executable, arguments: arguments, env: env, cwd: cwd,
          loginShell: viaLoginShell ? (loginShell ?? .current()) : nil)
      } catch {
        return .spawnFailed(reason: error.reason)
      }
      outcome = await runGated(launch, timeout: timeout, maxOutputBytes: maxOutputBytes)
      guard case .exited(let code, _, let stderr, _) = outcome,
        LoginShellLaunch.reportsMissingCommand(exitCode: code, stderr: String(bytes: stderr, encoding: .utf8) ?? ""),
        !Task.isCancelled
      else { break }
    }
    return outcome
  }

  private func runGated(_ launch: ProcessLaunch, timeout: Duration, maxOutputBytes: Int) async -> CommandOutcome {
    await Self.gate.acquire()
    // `defer` can't await, so release on a detached task — this still runs if
    // the surrounding task is cancelled or `launch` returns early.
    defer { Task { await Self.gate.release() } }
    return await run(launch, timeout: timeout, maxOutputBytes: maxOutputBytes)
  }

  /// The `.spawnFailed` reason for a working directory that is not on This Mac.
  static func nonLocalDirectoryReason(_ cwd: URL) -> String {
    "working directory is not a local path: \(cwd.absoluteString)"
  }

  private func run(_ launch: ProcessLaunch, timeout: Duration, maxOutputBytes: Int) async -> CommandOutcome {
    let process = Process()
    process.executableURL = launch.executable
    process.arguments = launch.arguments
    process.currentDirectoryURL = launch.currentDirectory
    process.environment = launch.environment
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe.closeOnExec()
    let stderrPipe = Pipe.closeOnExec()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Install the termination continuation FIRST. AsyncStream.makeStream() gives us a
    // handle-continuation pair that's live before we touch the Process's handler slot.
    let (exitStream, exitCont) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { p in
      exitCont.yield(p.terminationStatus)
      exitCont.finish()
    }

    let stdoutCollector = PipeCollector(pipe: stdoutPipe, maxBytes: maxOutputBytes)
    let stderrCollector = PipeCollector(pipe: stderrPipe, maxBytes: maxOutputBytes)
    let grace = eofGrace

    // Now start the child.
    do {
      try process.run()
    } catch let error as NSError {
      exitCont.finish()
      // Explicitly close pipe write ends so the drains see EOF and complete. Relying on
      // Pipe.deinit to close implicitly is fragile under the task-group lifetimes here.
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      _ = await stdoutCollector.finish(grace: grace)
      _ = await stderrCollector.finish(grace: grace)
      if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
        return .spawnFailed(reason: "binary not found: \(launch.executable.path)")
      }
      return .spawnFailed(reason: error.localizedDescription)
    }

    // Race exit vs. timeout.
    let outcome = await Self.awaitExitOrTimeout(
      exitStream: exitStream, process: process, timeout: timeout
    )
    async let stdoutResult = stdoutCollector.finish(grace: grace)
    async let stderrResult = stderrCollector.finish(grace: grace)
    let (stdoutData, stdoutOverflow) = await stdoutResult
    let (stderrData, _) = await stderrResult
    switch outcome {
    case .exited(let code):
      return .exited(code: code, stdout: stdoutData, stderr: stderrData, stdoutOverflow: stdoutOverflow)
    case .timedOut:
      return .timedOut
    }
  }

  private enum ExitOrTimeout: Sendable {
    case exited(Int32)
    case timedOut
  }

  /// Consumes `exitStream` with a timeout race. On timeout, sends SIGTERM + grace + SIGKILL
  /// so no stuck child survives, then returns `.timedOut`.
  private static func awaitExitOrTimeout(
    exitStream: AsyncStream<Int32>,
    process: Process,
    timeout: Duration
  ) async -> ExitOrTimeout {
    await withTaskGroup(of: ExitOrTimeout.self) { group in
      group.addTask {
        for await code in exitStream { return .exited(code) }
        return .exited(Int32(-1))  // stream finished without value — shouldn't happen
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return .timedOut
      }
      defer { group.cancelAll() }
      guard let first = await group.next() else { return .exited(Int32(-1)) }
      // A cancelled caller ends both child tasks at once, and the exit stream
      // can win with a placeholder code while the child still runs.
      if case .exited(let code) = first, !Task.isCancelled { return .exited(code) }
      await terminate(process)
      return .timedOut
    }
  }

  /// SIGTERM, a grace second, then SIGKILL. `Process` starts each child in its
  /// own process group, so the signals also reach what it started: a login
  /// shell's rc commands, git's credential helper or `ssh`.
  private static func terminate(_ process: Process) async {
    let pid = process.processIdentifier
    let target = getpgid(pid) == pid ? -pid : pid
    kill(target, SIGTERM)
    // Detached: a cancelled caller's `Task.sleep` returns at once, and the
    // grace must still pass.
    await Task.detached {
      try? await Task.sleep(for: .seconds(1))
    }.value
    kill(target, SIGKILL)
  }
}

/// Test double. Tests pre-seed a list of `CommandOutcome` values; each call dequeues one.
/// Records every invocation for assertion.
actor RecordingCommandRunner: CommandRunner {
  struct Recorded: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var env: [String: String]
    var cwd: URL
    var timeout: Duration
    var maxOutputBytes: Int
    var launch: CommandLaunch
  }

  private var _calls: [Recorded] = []
  private var outcomes: [CommandOutcome]

  init(outcomes: [CommandOutcome] = [.exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)]) {
    self.outcomes = outcomes
  }

  var calls: [Recorded] { _calls }

  nonisolated func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int,
    launch: CommandLaunch
  ) async -> CommandOutcome {
    await record(
      executable: executable, arguments: arguments, env: env,
      cwd: cwd, timeout: timeout, maxOutputBytes: maxOutputBytes, launch: launch
    )
  }

  private func record(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int,
    launch: CommandLaunch
  ) -> CommandOutcome {
    _calls.append(
      Recorded(
        executable: executable,
        arguments: arguments,
        env: env,
        cwd: cwd,
        timeout: timeout,
        maxOutputBytes: maxOutputBytes,
        launch: launch
      ))
    if let outcome = outcomes.first {
      if outcomes.count > 1 { outcomes.removeFirst() }
      return outcome
    }
    return .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
  }
}
