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

  /// Runs a command and passes each output line to `onLine` while it runs:
  /// stdout and stderr lines, each stream in order. The same launch modes,
  /// timeout, and cancel behavior as `run`. For long commands that report
  /// progress (a clone, the bundled `wt`, a setup script).
  ///
  /// `splitOnCarriageReturn` also ends a line at `\r`, so progress output
  /// that redraws one line (`git clone --progress`) streams each redraw.
  /// `onSpawn` gets the pid of every started attempt.
  func runStream(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    launch: CommandLaunch,
    splitOnCarriageReturn: Bool,
    onSpawn: @escaping @Sendable (pid_t) -> Void,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> CommandStreamOutcome
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

  func runStream(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    launch: CommandLaunch,
    splitOnCarriageReturn: Bool = false,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> CommandStreamOutcome {
    await runStream(
      executable: executable, arguments: arguments, env: env, cwd: cwd, timeout: timeout, launch: launch,
      splitOnCarriageReturn: splitOnCarriageReturn, onSpawn: { _ in }, onLine: onLine)
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

/// How a streamed command ended (`CommandRunner.runStream`).
nonisolated enum CommandStreamOutcome: Equatable, Sendable {
  /// The child exited within the timeout. `lastStdoutLine` is the last
  /// non-empty stdout line, trimmed. `stderr` is all stderr output, up to
  /// `FoundationCommandRunner.streamStderrCap` bytes.
  case exited(code: Int32, lastStdoutLine: String, stderr: String)
  /// The child was still running at the deadline. The runner stopped its
  /// process group.
  case timedOut
  /// The calling task was cancelled. The runner stopped the process group.
  case cancelled
  /// The command could not start. `reason` is for the user.
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

  /// How much stderr a streamed command keeps for its error report.
  static let streamStderrCap = 4 * 1024 * 1024

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
    await attempts(
      executable: executable, arguments: arguments, env: env, cwd: cwd, mode: mode,
      spawnFailed: { .spawnFailed(reason: $0) },
      reportsMissingCommand: { outcome in
        guard case .exited(let code, _, let stderr, _) = outcome else { return false }
        return LoginShellLaunch.reportsMissingCommand(
          exitCode: code, stderr: String(bytes: stderr, encoding: .utf8) ?? "")
      },
      body: { launch in await runGated(launch, timeout: timeout, maxOutputBytes: maxOutputBytes) })
  }

  /// Not gated by `gate`: a stream can run for many minutes (a clone, a
  /// setup script), and holding a slot that long would stall the short
  /// commands the gate exists for.
  func runStream(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    launch mode: CommandLaunch,
    splitOnCarriageReturn: Bool,
    onSpawn: @escaping @Sendable (pid_t) -> Void,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> CommandStreamOutcome {
    await attempts(
      executable: executable, arguments: arguments, env: env, cwd: cwd, mode: mode,
      spawnFailed: { .spawnFailed(reason: $0) },
      reportsMissingCommand: { outcome in
        guard case .exited(let code, _, let stderr) = outcome else { return false }
        return LoginShellLaunch.reportsMissingCommand(exitCode: code, stderr: stderr)
      },
      body: { launch in
        await stream(
          launch, timeout: timeout, splitOnCarriageReturn: splitOnCarriageReturn, onSpawn: onSpawn, onLine: onLine)
      })
  }

  /// Runs one attempt per entry of `mode.attemptsViaLoginShell`; a later
  /// attempt runs only when the one before it reported a missing command.
  private func attempts<Outcome>(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    mode: CommandLaunch,
    spawnFailed: (String) -> Outcome,
    reportsMissingCommand: (Outcome) -> Bool,
    body: (ProcessLaunch) async -> Outcome
  ) async -> Outcome {
    // `Process.currentDirectoryURL` raises an Objective-C exception for a
    // non-file URL (a Remote Project's `codans-host://` location). Return an
    // error instead: a location that reaches this runner unresolved is a
    // routing bug, not a reason to stop the app.
    guard cwd.isFileURL else { return spawnFailed(Self.nonLocalDirectoryReason(cwd)) }
    var outcome = spawnFailed("no launch")
    for viaLoginShell in mode.attemptsViaLoginShell {
      let launch: ProcessLaunch
      do {
        launch = try ProcessLaunch.make(
          executable: executable, arguments: arguments, env: env, cwd: cwd,
          loginShell: viaLoginShell ? (loginShell ?? .current()) : nil)
      } catch {
        return spawnFailed(error.reason)
      }
      outcome = await body(launch)
      guard reportsMissingCommand(outcome), !Task.isCancelled else { break }
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
    let result = await execute(
      launch, timeout: timeout,
      stdout: { PipeCollector(pipe: $0, maxBytes: maxOutputBytes) },
      stderr: { PipeCollector(pipe: $0, maxBytes: maxOutputBytes) },
      onSpawn: { _ in })
    switch result.ending {
    case .exited(let code):
      return .exited(
        code: code, stdout: result.stdout.data, stderr: result.stderr.data, stdoutOverflow: result.stdout.overflow)
    case .timedOut, .cancelled:
      return .timedOut
    case .spawnFailed(let reason):
      return .spawnFailed(reason: reason)
    }
  }

  private func stream(
    _ launch: ProcessLaunch,
    timeout: Duration,
    splitOnCarriageReturn: Bool,
    onSpawn: @escaping @Sendable (pid_t) -> Void,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> CommandStreamOutcome {
    let stdoutLines = LineSplitter(splitOnCarriageReturn: splitOnCarriageReturn)
    let stderrLines = LineSplitter(splitOnCarriageReturn: splitOnCarriageReturn)
    let result = await execute(
      launch, timeout: timeout,
      stdout: { pipe in
        PipeCollector(pipe: pipe, maxBytes: 0) { chunk in stdoutLines.consume(chunk).forEach(onLine) }
      },
      stderr: { pipe in
        PipeCollector(pipe: pipe, maxBytes: Self.streamStderrCap) { chunk in
          stderrLines.consume(chunk).forEach(onLine)
        }
      },
      onSpawn: onSpawn)
    // The collectors are done, so no chunk can race these flushes.
    stdoutLines.flush().forEach(onLine)
    stderrLines.flush().forEach(onLine)
    switch result.ending {
    case .exited(let code):
      return .exited(
        code: code, lastStdoutLine: stdoutLines.lastNonEmpty,
        stderr: String(bytes: result.stderr.data, encoding: .utf8) ?? "")
    case .timedOut: return .timedOut
    case .cancelled: return .cancelled
    case .spawnFailed(let reason): return .spawnFailed(reason: reason)
    }
  }

  private enum Ending: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
    case spawnFailed(String)
  }

  private struct Execution {
    var ending: Ending
    var stdout: (data: Data, overflow: Bool)
    var stderr: (data: Data, overflow: Bool)
  }

  /// Starts one process, waits for its exit, the timeout, or the caller's
  /// cancel, and collects its output. `stdout` / `stderr` make the
  /// collectors for the two pipes.
  private func execute(
    _ launch: ProcessLaunch,
    timeout: Duration,
    stdout makeStdoutCollector: (Pipe) -> PipeCollector,
    stderr makeStderrCollector: (Pipe) -> PipeCollector,
    onSpawn: (pid_t) -> Void
  ) async -> Execution {
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

    let stdoutCollector = makeStdoutCollector(stdoutPipe)
    let stderrCollector = makeStderrCollector(stderrPipe)
    let grace = eofGrace

    // Now start the child.
    let ending: Ending
    do {
      try process.run()
      onSpawn(process.processIdentifier)
      ending = await Self.awaitExitOrTimeout(exitStream: exitStream, process: process, timeout: timeout)
    } catch let error as NSError {
      exitCont.finish()
      // Explicitly close pipe write ends so the drains see EOF and complete. Relying on
      // Pipe.deinit to close implicitly is fragile under the task-group lifetimes here.
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
        ending = .spawnFailed("binary not found: \(launch.executable.path)")
      } else {
        ending = .spawnFailed(error.localizedDescription)
      }
    }
    async let stdoutResult = stdoutCollector.finish(grace: grace)
    async let stderrResult = stderrCollector.finish(grace: grace)
    let (stdout, stderr) = await (stdoutResult, stderrResult)
    return Execution(ending: ending, stdout: stdout, stderr: stderr)
  }

  /// Consumes `exitStream` with a timeout race. On timeout or cancel, sends
  /// SIGTERM + grace + SIGKILL so no stuck child survives.
  private static func awaitExitOrTimeout(
    exitStream: AsyncStream<Int32>,
    process: Process,
    timeout: Duration
  ) async -> Ending {
    await withTaskGroup(of: Ending.self) { group in
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
      let cancelled = Task.isCancelled
      if case .exited(let code) = first, !cancelled { return .exited(code) }
      await terminate(process)
      return cancelled ? .cancelled : .timedOut
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

  /// Records the call like `run` and reports a clean exit with no output.
  nonisolated func runStream(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    launch: CommandLaunch,
    splitOnCarriageReturn: Bool,
    onSpawn: @escaping @Sendable (pid_t) -> Void,
    onLine: @escaping @Sendable (String) -> Void
  ) async -> CommandStreamOutcome {
    _ = await record(
      executable: executable, arguments: arguments, env: env,
      cwd: cwd, timeout: timeout, maxOutputBytes: 0, launch: launch
    )
    return .exited(code: 0, lastStdoutLine: "", stderr: "")
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
