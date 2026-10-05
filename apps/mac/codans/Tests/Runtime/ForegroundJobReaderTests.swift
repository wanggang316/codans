import CodansCore
import Darwin
import Foundation
import Testing

@testable import Codans

struct ForegroundJobReaderTests {
  @Test
  func procargs2ArgvReadsKernelArgumentBuffer() {
    let buffer = Self.procargsBuffer(
      execPath: "/usr/bin/node",
      argv: ["/usr/bin/node", "/Users/me/.npm/bin/codex.js", "--resume"]
    )

    #expect(
      ForegroundJobReader.procargs2Argv(buffer) == [
        "/usr/bin/node",
        "/Users/me/.npm/bin/codex.js",
        "--resume",
      ]
    )
  }

  @Test
  func procargs2ArgvRejectsIncompleteBuffers() {
    #expect(ForegroundJobReader.procargs2Argv([]) == nil)
    #expect(ForegroundJobReader.procargs2Argv([0, 0, 0, 0]) == nil)
  }

  @Test
  func procargs2ArgvPreservesEmptyArguments() {
    let buffer = Self.procargsBuffer(
      execPath: "/usr/bin/node",
      argv: ["/usr/bin/node", "", "codex"]
    )

    #expect(
      ForegroundJobReader.procargs2Argv(buffer) == [
        "/usr/bin/node",
        "",
        "codex",
      ]
    )
  }

  @Test
  func processGroupPIDsRejectsInvalidGroups() {
    #expect(ForegroundJobReader.processGroupPIDs(0).isEmpty)
    #expect(ForegroundJobReader.processGroupPIDs(-1).isEmpty)
  }

  @Test
  func processArgumentsReadsCurrentProcess() {
    let arguments = ForegroundJobReader.processArguments(pid: getpid())
    #expect(arguments?.isEmpty == false)
  }

  @Test
  func processSampleIncludesKernelStartTime() throws {
    let process = try #require(ForegroundJobReader.process(pid: getpid()))
    let startedAt = try #require(process.startedAt)
    #expect(startedAt == ForegroundJobReader.processStartedAt(pid: getpid()))
    #expect(startedAt <= Date.now)
  }

  @Test
  func legacyRemoteSampleDecodesWithoutStartTime() throws {
    let data = Data(
      #"{"pid":12,"parentPID":1,"processGroupID":12,"argv0":"node","commandLine":"node server.js"}"#.utf8
    )
    let process = try JSONDecoder().decode(ForegroundProcess.self, from: data)
    #expect(process.startedAt == nil)
    #expect(process.pid == 12)
  }

  @Test
  func processStartTimeSurvivesCoding() throws {
    let process = try #require(ForegroundJobReader.process(pid: getpid()))
    let decoded = try JSONDecoder().decode(ForegroundProcess.self, from: JSONEncoder().encode(process))
    #expect(decoded == process)
  }

  // `foregroundProcessGroupID(childPID:)` is handed login(1) for an
  // interactive pane — a root-owned process this user cannot
  // `proc_pidinfo` — so these pin the sysctl read.
  @Test
  func invalidOrVanishedPIDHasNoGroup() throws {
    #expect(ForegroundJobReader.foregroundProcessGroupID(childPID: 0) == nil)
    #expect(ForegroundJobReader.foregroundProcessGroupID(childPID: -1) == nil)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try proc.run()
    proc.waitUntilExit()
    #expect(ForegroundJobReader.foregroundProcessGroupID(childPID: proc.processIdentifier) == nil)
  }

  @Test
  func processOnATerminalReportsItsForegroundGroup() async throws {
    // script(1) gives `sleep` a pty it controls, so it is the foreground
    // group of its own terminal.
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    script.arguments = ["-q", "/dev/null", "/bin/sleep", "10"]
    script.standardInput = FileHandle.nullDevice
    script.standardOutput = FileHandle.nullDevice
    try script.run()
    defer { script.terminate() }

    var sleepPID: pid_t?
    for _ in 0..<50 where sleepPID == nil {
      sleepPID = Self.childPID(of: script.processIdentifier)
      if sleepPID == nil { try await Task.sleep(for: .milliseconds(50)) }
    }
    let pid = try #require(sleepPID)
    defer { kill(pid, SIGTERM) }
    #expect(ForegroundJobReader.foregroundProcessGroupID(childPID: pid) == getpgid(pid))
  }

  private static func childPID(of parent: pid_t) -> pid_t? {
    var pids = [pid_t](repeating: 0, count: 64)
    let bytes = pids.withUnsafeMutableBufferPointer {
      proc_listchildpids(parent, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
    }
    return bytes > 0 ? pids.first(where: { $0 > 0 }) : nil
  }
  private static func procargsBuffer(execPath: String, argv: [String]) -> [UInt8] {
    var argc = Int32(argv.count)
    var buffer = withUnsafeBytes(of: &argc) { Array($0) }
    buffer.append(contentsOf: execPath.utf8)
    buffer.append(0)
    buffer.append(0)
    for argument in argv {
      buffer.append(contentsOf: argument.utf8)
      buffer.append(0)
    }
    return buffer
  }
}
