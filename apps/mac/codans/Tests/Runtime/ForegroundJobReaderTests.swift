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
