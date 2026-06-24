import Foundation
import Testing
import CodansIPC

@testable import CodansKit

struct CLIExitCodeTests {
  @Test
  func ipcErrorMappingIsStable() {
    // Pin the mapping so future IPCError cases force a decision here.
    #expect(CLIExitCode.from(.unknownMethod("foo")) == .userError)
    #expect(CLIExitCode.from(.invalidParams(message: "x", path: nil)) == .userError)
    #expect(CLIExitCode.from(.notFound(kind: "pane", id: "x")) == .notFound)
    #expect(CLIExitCode.from(.conflict(reason: "x")) == .conflict)
    #expect(CLIExitCode.from(.unsupported(reason: "x")) == .unsupported)
    #expect(CLIExitCode.from(.overloaded) == .overloaded)
    #expect(CLIExitCode.from(.versionMismatch(client: "a", server: "b")) == .versionMismatch)
    #expect(CLIExitCode.from(.invalidFrame(reason: "x")) == .internal)
    #expect(CLIExitCode.from(.internal("x")) == .internal)
  }

  @Test
  func rawValuesMatchC4DesignDoc() {
    // Agents branch on exit codes — must not change within a major.
    #expect(CLIExitCode.ok.rawValue == 0)
    #expect(CLIExitCode.userError.rawValue == 1)
    #expect(CLIExitCode.notFound.rawValue == 2)
    #expect(CLIExitCode.conflict.rawValue == 3)
    #expect(CLIExitCode.unsupported.rawValue == 4)
    #expect(CLIExitCode.overloaded.rawValue == 5)
    #expect(CLIExitCode.versionMismatch.rawValue == 6)
    #expect(CLIExitCode.noSocket.rawValue == 10)
    #expect(CLIExitCode.requestTimeout.rawValue == 11)
    #expect(CLIExitCode.launchTimeout.rawValue == 12)
    #expect(CLIExitCode.internal.rawValue == 20)
  }
}
