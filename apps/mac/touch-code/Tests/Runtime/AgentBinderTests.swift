import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Behavioural coverage for `AgentBinder`. Foreground job snapshots are
/// the only identity signal accepted by the binder.
@MainActor
struct AgentBinderTests {
  @Test
  func paneCreatedDoesNotBindFromInitialCommand() {
    let f = Fixture()
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func foregroundJobBindsDirectAgentProcess() {
    let f = Fixture()
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex --resume"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  @Test
  func foregroundJobRebindsAlreadyBoundPane() {
    let f = Fixture(initialAgentKind: .claudeCode)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  @Test
  func foregroundJobClearsWhenNoAgentProcessRemains() {
    let f = Fixture(initialAgentKind: .codex)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "-zsh", commandLine: "-zsh"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: nil)])
  }

  @Test
  func foregroundJobWithSameKindIsNoOp() {
    let f = Fixture(initialAgentKind: .codex)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex"))
    )
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func unbindAlwaysCallsThroughWithNil() {
    let f = Fixture(initialAgentKind: .claudeCode)
    f.binder.unbind(f.paneID)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: nil)])
  }

  private static func job(argv0: String, commandLine: String) -> ForegroundJob {
    ForegroundJob(
      processGroupID: 123,
      processes: [
        ForegroundProcess(
          pid: 123,
          parentPID: 122,
          processGroupID: 123,
          argv0: argv0,
          commandLine: commandLine
        )
      ]
    )
  }

  @MainActor
  final class Fixture {
    let paneID = PaneID()
    let calls = LockIsolated<[RecordedCall]>([])
    let agentKind: LockIsolated<AgentKind?>
    let binder: AgentBinder

    init(initialAgentKind: AgentKind? = nil) {
      self.agentKind = LockIsolated(initialAgentKind)

      var hierarchyClient = HierarchyClient.testValue
      let calls = self.calls
      let agentKind = self.agentKind
      hierarchyClient.setPaneAgentKind = { paneID, kind in
        calls.withValue { $0.append(RecordedCall(paneID: paneID, kind: kind)) }
        agentKind.setValue(kind)
      }

      self.binder = AgentBinder(
        client: hierarchyClient,
        currentAgentKind: { _ in agentKind.value }
      )
    }
  }

  struct RecordedCall: Equatable {
    let paneID: PaneID
    let kind: AgentKind?
  }
}
