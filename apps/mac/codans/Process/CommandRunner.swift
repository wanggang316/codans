import Foundation

/// Shared subprocess primitive used by any in-app module that shells out — `codans/Git/`
/// for `git`, `codans/GitHub/` for `gh`, and so on. The live implementation wraps
/// `Foundation.Process`; tests inject `RecordingCommandRunner` to exercise timeout /
/// output-cap / non-zero-exit paths without a real child process.
///
/// The runner intentionally does not know about any domain error type — it reports a
/// mechanical `CommandOutcome`, and each caller translates that into its own richer error
/// (`GitError`, `GitHubError`, …).
nonisolated protocol CommandRunner: Sendable {
  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int
  ) async -> CommandOutcome
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

/// Live implementation. Correctness-critical points (see 0005 M2 review feedback):
///
/// - `terminationHandler` is installed **synchronously** before `process.run()`, so an exit
///   that lands between `run()` returning and our await arriving still resumes our
///   continuation. Previously a `Task.detached { withCheckedContinuation { … } }` introduced
///   a race window.
/// - Pipe drains run on `DispatchQueue.global(qos: .utility)`, not on the Swift cooperative
///   pool. Blocking reads from `FileHandle.availableData` won't starve other tasks.
nonisolated struct FoundationCommandRunner: CommandRunner {
  /// Caps concurrent child-process launches across every caller. Foundation's
  /// `Process` / `Pipe` machinery races under heavy concurrent spawning, and
  /// the launch-time git status/diff fan-out across many worktrees can
  /// otherwise spawn dozens at once — which intermittently corrupted the heap
  /// (an `EXC_BAD_ACCESS` that surfaced later in unrelated task allocation).
  /// A modest cap keeps the fan-out fast while staying clear of that contention.
  private static let gate = SubprocessGate(limit: 6)

  func run(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int
  ) async -> CommandOutcome {
    await Self.gate.acquire()
    // `defer` can't await, so release on a detached task — this still runs if
    // the surrounding task is cancelled or `launch` returns early.
    defer { Task { await Self.gate.release() } }
    return await launch(
      executable: executable,
      arguments: arguments,
      env: env,
      cwd: cwd,
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
  }

  private func launch(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int
  ) async -> CommandOutcome {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = env
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Install the termination continuation FIRST. AsyncStream.makeStream() gives us a
    // handle-continuation pair that's live before we touch the Process's handler slot.
    let (exitStream, exitCont) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { p in
      exitCont.yield(p.terminationStatus)
      exitCont.finish()
    }

    // Drain pipes on a background queue (NOT the cooperative pool — blocking reads here are
    // expected). `async let` bridges back into the concurrency world without tying up a task.
    async let stdoutResult: (data: Data, overflow: Bool) = Self.drain(
      pipe: stdoutPipe, maxBytes: maxOutputBytes
    )
    async let stderrResult: (data: Data, overflow: Bool) = Self.drain(
      pipe: stderrPipe, maxBytes: maxOutputBytes
    )

    // Now start the child.
    do {
      try process.run()
    } catch let error as NSError {
      exitCont.finish()
      // Explicitly close pipe write ends so the drains see EOF and complete. Relying on
      // Pipe.deinit to close implicitly is fragile under the task-group lifetimes here.
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      _ = await stdoutResult
      _ = await stderrResult
      if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
        return .spawnFailed(reason: "binary not found: \(executable.path)")
      }
      return .spawnFailed(reason: error.localizedDescription)
    }

    // Race exit vs. timeout.
    let outcome = await Self.awaitExitOrTimeout(
      exitStream: exitStream, process: process, timeout: timeout
    )
    switch outcome {
    case .exited(let code):
      let (stdoutData, stdoutOverflow) = await stdoutResult
      let (stderrData, _) = await stderrResult
      return .exited(code: code, stdout: stdoutData, stderr: stderrData, stdoutOverflow: stdoutOverflow)
    case .timedOut:
      _ = await stdoutResult
      _ = await stderrResult
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
      switch first {
      case .exited(let code):
        return .exited(code)
      case .timedOut:
        process.terminate()
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
        }
        return .timedOut
      }
    }
  }

  /// Drains a pipe to EOF on a dedicated background queue. Past `maxBytes`, further bytes are
  /// discarded but the loop continues so the child never blocks on a full pipe.
  private static func drain(pipe: Pipe, maxBytes: Int) async -> (data: Data, overflow: Bool) {
    await withCheckedContinuation { (cont: CheckedContinuation<(Data, Bool), Never>) in
      DispatchQueue.global(qos: .utility).async {
        var buffer = Data()
        buffer.reserveCapacity(min(maxBytes, 64 * 1024))
        var overflow = false
        let handle = pipe.fileHandleForReading
        while true {
          let chunk = handle.availableData
          if chunk.isEmpty { break }
          if buffer.count + chunk.count > maxBytes {
            let remaining = maxBytes - buffer.count
            if remaining > 0 { buffer.append(chunk.prefix(remaining)) }
            overflow = true
            // Drain-past-cap contract: keep reading to EOF so the child doesn't block on a
            // full pipe, but discard the excess bytes to bound memory.
          } else {
            buffer.append(chunk)
          }
        }
        cont.resume(returning: (buffer, overflow))
      }
    }
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
    maxOutputBytes: Int
  ) async -> CommandOutcome {
    await record(
      executable: executable, arguments: arguments, env: env,
      cwd: cwd, timeout: timeout, maxOutputBytes: maxOutputBytes
    )
  }

  private func record(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL,
    timeout: Duration,
    maxOutputBytes: Int
  ) -> CommandOutcome {
    _calls.append(
      Recorded(
        executable: executable,
        arguments: arguments,
        env: env,
        cwd: cwd,
        timeout: timeout,
        maxOutputBytes: maxOutputBytes
      ))
    if let outcome = outcomes.first {
      if outcomes.count > 1 { outcomes.removeFirst() }
      return outcome
    }
    return .exited(code: 0, stdout: Data(), stderr: Data(), stdoutOverflow: false)
  }
}
