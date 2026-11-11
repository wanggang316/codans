import Darwin
import Foundation
import Testing

@testable import Codans

/// Lines a stream reported, collected from any thread.
final class LockedLines: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []

  func append(_ line: String) { lock.withLock { lines.append(line) } }
  var all: [String] { lock.withLock { lines } }
}

/// The pids a stream started, and whether each led its own process group.
final class SpawnRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var pids: [pid_t] = []
  private var leaders: [Bool] = []

  func record(_ pid: pid_t) {
    let leads = getpgid(pid) == pid
    lock.withLock {
      pids.append(pid)
      leaders.append(leads)
    }
  }

  var all: [pid_t] { lock.withLock { pids } }
  var allLeadTheirGroup: Bool { lock.withLock { !leaders.isEmpty && !leaders.contains(false) } }

  /// Waits until `count` children started.
  func waitForSpawns(_ count: Int, within limit: Duration = .seconds(10)) async throws {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while all.count < count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// True once no process is left in the group `pid` led.
func processGroupEnds(_ pid: pid_t, within limit: Duration = .seconds(5)) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: limit)
  while ContinuousClock.now < deadline {
    if kill(-pid, 0) == -1, errno == ESRCH { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return false
}

struct CommandRunnerStreamTests {
  private let runner = FoundationCommandRunner(eofGrace: .milliseconds(200))
  private let sh = URL(fileURLWithPath: "/bin/sh")
  private let cwd = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  private let env = ["PATH": "/usr/bin:/bin"]

  @Test
  func linesArriveInOrder() async {
    let lines = LockedLines()
    let outcome = await runner.runStream(
      executable: sh, arguments: ["-c", "i=1; while [ $i -le 500 ]; do echo line$i; i=$((i+1)); done; printf tail"],
      env: env, cwd: cwd, timeout: .seconds(30), launch: .direct, onLine: { lines.append($0) })
    #expect(outcome == .exited(code: 0, lastStdoutLine: "tail", stderr: ""))
    #expect(lines.all == (1...500).map { "line\($0)" } + ["tail"])
  }

  @Test
  func carriageReturnEndsALineOnlyWhenAsked() async {
    let script = "printf 'a\\rb\\nc\\n'"
    let split = LockedLines()
    _ = await runner.runStream(
      executable: sh, arguments: ["-c", script], env: env, cwd: cwd, timeout: .seconds(30), launch: .direct,
      splitOnCarriageReturn: true, onLine: { split.append($0) })
    #expect(split.all == ["a", "b", "c"])
    let whole = LockedLines()
    _ = await runner.runStream(
      executable: sh, arguments: ["-c", script], env: env, cwd: cwd, timeout: .seconds(30), launch: .direct,
      onLine: { whole.append($0) })
    #expect(whole.all == ["a\rb", "c"])
  }

  @Test
  func exitCodeAndStderrAreReported() async {
    let lines = LockedLines()
    let outcome = await runner.runStream(
      executable: sh, arguments: ["-c", "echo out; echo oops >&2; exit 3"], env: env, cwd: cwd,
      timeout: .seconds(30), launch: .direct, onLine: { lines.append($0) })
    #expect(outcome == .exited(code: 3, lastStdoutLine: "out", stderr: "oops\n"))
    #expect(Set(lines.all) == ["out", "oops"])
  }

  @Test
  func missingExecutableFailsToSpawn() async {
    let outcome = await runner.runStream(
      executable: URL(fileURLWithPath: "/nonexistent/codans-tool"), arguments: [], env: env, cwd: cwd,
      timeout: .seconds(5), launch: .direct, onLine: { _ in })
    guard case .spawnFailed = outcome else {
      Issue.record("expected .spawnFailed, got \(outcome)")
      return
    }
  }

  /// The background `sleep` shares the group; it must stop with the shell.
  @Test
  func timeoutStopsTheProcessGroup() async throws {
    let spawns = SpawnRecorder()
    let lines = LockedLines()
    let outcome = await runner.runStream(
      executable: sh, arguments: ["-c", "sleep 30 & echo started; wait"], env: env, cwd: cwd,
      timeout: .milliseconds(500), launch: .direct, splitOnCarriageReturn: false,
      onSpawn: { spawns.record($0) }, onLine: { lines.append($0) })
    #expect(outcome == .timedOut)
    #expect(lines.all == ["started"])
    let pid = try #require(spawns.all.first)
    #expect(spawns.allLeadTheirGroup)
    #expect(await processGroupEnds(pid))
  }

  @Test
  func cancelStopsTheProcessGroup() async throws {
    let spawns = SpawnRecorder()
    let task = Task {
      await runner.runStream(
        executable: sh, arguments: ["-c", "sleep 30 & wait"], env: env, cwd: cwd,
        timeout: .seconds(60), launch: .direct, splitOnCarriageReturn: false,
        onSpawn: { spawns.record($0) }, onLine: { _ in })
    }
    try await spawns.waitForSpawns(1)
    let pid = try #require(spawns.all.first)
    task.cancel()
    #expect(await task.value == .cancelled)
    #expect(spawns.allLeadTheirGroup)
    #expect(await processGroupEnds(pid))
  }

  /// A direct run that exits 127 runs once more through the login shell,
  /// and only once.
  @Test
  func missingCommandRetriesOnceThroughTheLoginShell() async throws {
    let home = FileManager.default.temporaryDirectory
      .appending(path: "codans-stream-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let script = home.appending(path: "missing-tool")
    try "#!/bin/sh\necho attempt\nexit 127\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let loginRunner = FoundationCommandRunner(
      eofGrace: .milliseconds(200), loginShell: .zsh(URL(fileURLWithPath: "/bin/zsh")))
    let spawns = SpawnRecorder()
    let lines = LockedLines()
    let outcome = await loginRunner.runStream(
      executable: script, arguments: [], env: ["HOME": home.path, "PATH": "/usr/bin:/bin"], cwd: home,
      timeout: .seconds(30), launch: .directThenLoginShell, splitOnCarriageReturn: false,
      onSpawn: { spawns.record($0) }, onLine: { lines.append($0) })
    #expect(outcome == .exited(code: 127, lastStdoutLine: "attempt", stderr: ""))
    #expect(spawns.all.count == 2)
    #expect(lines.all == ["attempt", "attempt"])

    let directSpawns = SpawnRecorder()
    _ = await loginRunner.runStream(
      executable: script, arguments: [], env: ["HOME": home.path, "PATH": "/usr/bin:/bin"], cwd: home,
      timeout: .seconds(30), launch: .direct, splitOnCarriageReturn: false,
      onSpawn: { directSpawns.record($0) }, onLine: { _ in })
    #expect(directSpawns.all.count == 1)
  }

  @Test
  func splitterKeepsAMultiByteCharacterCutAcrossReads() {
    let splitter = LineSplitter(splitOnCarriageReturn: false)
    let bytes = Data("é\n".utf8)
    #expect(splitter.consume(bytes.prefix(1)).isEmpty)
    #expect(splitter.consume(bytes.dropFirst()) == ["é"])
    #expect(splitter.flush().isEmpty)
  }
}
