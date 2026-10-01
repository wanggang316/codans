import Foundation
import Testing

@testable import Codans

@Suite(.serialized)
struct CommandRunnerCancellationTests {
  @Test
  func cancellationTerminatesAnAlreadyRunningProcess() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let task = Task {
      await run("echo $$ > pid; exec /bin/sleep 30", in: directory)
    }
    guard await waitForFiles([pidFile]) else {
      task.cancel()
      _ = await task.value
      Issue.record("The subprocess did not start")
      return
    }
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    task.cancel()
    _ = await task.value
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test
  func cancellationWhileWaitingForAGateSlotNeverExecutesTheCommand() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let blockers = (0..<6).map { index in
      Task {
        await run("echo ready > ready-\(index); exec /bin/sleep 30", in: directory)
      }
    }
    let ready = await waitForFiles((0..<6).map { directory.appendingPathComponent("ready-\($0)") })
    guard ready else {
      for task in blockers { task.cancel() }
      for task in blockers { _ = await task.value }
      Issue.record("The subprocess gate did not fill")
      return
    }
    let cancelled = Task {
      await run("echo executed > cancelled-ran", in: directory)
    }
    // Give the queued call an opportunity to enter the full gate.
    try await Task.sleep(for: .milliseconds(100))
    cancelled.cancel()
    for task in blockers { task.cancel() }
    for task in blockers { _ = await task.value }
    let outcome = await cancelled.value
    #expect(outcome == .spawnFailed(reason: "Command cancelled before launch"))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled-ran").path))
  }

  private func run(_ script: String, in directory: URL) async -> CommandOutcome {
    await FoundationCommandRunner().run(
      executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
      env: [:], cwd: directory, timeout: .seconds(35), maxOutputBytes: 1024
    )
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func waitForFiles(_ files: [URL]) async -> Bool {
    for _ in 0..<100 {
      if files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }
}
