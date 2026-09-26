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

  @Test
  func wrappedAgentUsesActualChildIdentityInsteadOfGroupLeader() throws {
    let startedAt = Date(timeIntervalSinceReferenceDate: 10)
    let wrapper = ForegroundProcess(
      pid: 120, parentPID: 100, processGroupID: 120, argv0: "/bin/sh",
      commandLine: "sh -c codex", startedAt: startedAt)
    let agent = ForegroundProcess(
      pid: 121, parentPID: 120, processGroupID: 120, argv0: "/opt/bin/codex",
      commandLine: "codex", startedAt: startedAt.addingTimeInterval(1))
    let match = try #require(
      ForegroundJobReader.agentIdentity(
        in: ForegroundJob(processGroupID: 120, processes: [wrapper, agent])))
    #expect(match.kind == .codex)
    #expect(match.process.processID == 121)
    #expect(match.process.processGroupID == 120)
    #expect(match.process.processStartedAt == agent.startedAt)
  }

  @Test
  func nodeEntrypointOwnsItsOwnVerifiedIdentity() throws {
    let process = ForegroundProcess(
      pid: 121, parentPID: 120, processGroupID: 120, argv0: "/usr/bin/node",
      commandLine: "node /opt/bin/codex.js", startedAt: Date(timeIntervalSinceReferenceDate: 10))
    let match = try #require(
      ForegroundJobReader.agentIdentity(
        in: ForegroundJob(processGroupID: 120, processes: [process])))
    #expect(match.kind == .codex)
    #expect(match.process.processID == 121)
  }

  @Test
  func ambiguousAgentProcessesCannotAuthorizeInput() {
    let startedAt = Date(timeIntervalSinceReferenceDate: 10)
    let processes = [121, 122].map { pid in
      ForegroundProcess(
        pid: Int32(pid), parentPID: 120, processGroupID: 120, argv0: "codex",
        commandLine: "codex", startedAt: startedAt)
    }
    let job = ForegroundJob(processGroupID: 120, processes: processes)
    #expect(AgentKindPatterns.classify(foregroundJob: job) == .codex)
    #expect(ForegroundJobReader.agentIdentity(in: job) == nil)
  }

  @Test
  func missingBirthTimeCannotAuthorizeInput() {
    let process = ForegroundProcess(
      pid: 121, parentPID: 120, processGroupID: 120, argv0: "codex", commandLine: "codex")
    #expect(
      ForegroundJobReader.agentIdentity(
        in: ForegroundJob(processGroupID: 120, processes: [process])) == nil)
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
