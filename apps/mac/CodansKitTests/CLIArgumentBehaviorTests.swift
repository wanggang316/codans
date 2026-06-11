import Foundation
import Testing
import CodansIPC

@testable import CodansKit

/// Parser-adjacent tests for command argument payloads that do not require a live server.
@MainActor
struct CLIArgumentBehaviorTests {
  // MARK: - codans broadcast scope validation

  @Test
  func broadcastScopeEncodingStableAcrossKinds() throws {
    let cases: [IPC.BroadcastScope] = [
      IPC.BroadcastScope(kind: .tab, target: UUID().uuidString),
      IPC.BroadcastScope(kind: .worktree, target: UUID().uuidString),
      IPC.BroadcastScope(kind: .label, target: "agent"),
    ]
    for scope in cases {
      let encoded = try JSONEncoder().encode(scope)
      let decoded = try JSONDecoder().decode(IPC.BroadcastScope.self, from: encoded)
      #expect(decoded == scope)
    }
  }

  // MARK: - CLIExitCode mapping on .unsupported + .conflict

  @Test
  func unsupportedMapsToExit4() {
    #expect(CLIExitCode.from(.unsupported(reason: "x")) == .unsupported)
  }

  @Test
  func conflictMapsToExit3() {
    // HierarchyError.invariantViolation surfaces as .conflict, which maps to exit 3.
    #expect(CLIExitCode.from(.conflict(reason: "duplicate")) == .conflict)
  }
}
