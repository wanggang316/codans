import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Behavioural coverage for `AgentBinder`. Foreground job snapshots are
/// the only identity signal accepted by the binder.
@MainActor
struct AgentBinderTests {
  @Test
  func foregroundJobBindsDirectAgentProcess() {
    let f = Fixture()
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex --resume"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
    #expect(
      f.boundCalls.value == [
        .init(paneID: f.paneID, kind: .codex, assumeUserInputSeen: false)
      ]
    )
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
  func reconcileMembershipLetsARetiredPaneMaterializeAgain() {
    let f = Fixture(initialAgentKind: .codex)
    let job = Self.job(argv0: "codex", commandLine: "codex")
    f.binder.consider(paneID: f.paneID, trigger: .foregroundJobChanged(job))
    f.binder.consider(paneID: f.paneID, trigger: .foregroundJobChanged(job))
    // Classified matches the existing binding, so the second pass takes the
    // noop branch — exactly one materialize so far.
    #expect(f.boundCalls.value.count == 1)

    // Archive's shape: the pane leaves `visiblePaneIDs()` while staying in
    // the catalog with its `agentKind` intact.
    f.binder.reconcileMembership(livePaneIDs: [])

    f.binder.consider(paneID: f.paneID, trigger: .foregroundJobChanged(job))
    #expect(f.boundCalls.value.count == 2)
    // The reconcile itself must not write a binding back through the client:
    // it runs from the catalog-mutation drain and would feed itself.
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func foregroundJobRetainsAcrossTransientMisses() {
    let f = Fixture(initialAgentKind: .codex)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "-zsh", commandLine: "-zsh"))
    )
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func foregroundJobClearsAfterRepeatedMisses() {
    let f = Fixture(initialAgentKind: .codex)
    for _ in 0..<6 {
      f.binder.consider(
        paneID: f.paneID,
        trigger: .foregroundJobChanged(Self.job(argv0: "-zsh", commandLine: "-zsh"))
      )
    }
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
    #expect(
      f.boundCalls.value == [
        .init(paneID: f.paneID, kind: .codex, assumeUserInputSeen: true)
      ]
    )
  }

  @Test
  func foregroundJobWithSameKindMaterializesOnlyOnce() {
    let f = Fixture(initialAgentKind: .codex)
    for _ in 0..<2 {
      f.binder.consider(
        paneID: f.paneID,
        trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex"))
      )
    }
    #expect(f.calls.value.isEmpty)
    #expect(f.boundCalls.value.count == 1)
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
    let boundCalls = LockIsolated<[RecordedBoundCall]>([])
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

      let boundCalls = self.boundCalls
      self.binder = AgentBinder(
        client: hierarchyClient,
        currentAgentKind: { _ in agentKind.value },
        agentBoundHandler: { paneID, kind, _, assumeUserInputSeen in
          boundCalls.withValue {
            $0.append(
              RecordedBoundCall(
                paneID: paneID,
                kind: kind,
                assumeUserInputSeen: assumeUserInputSeen
              )
            )
          }
        }
      )
    }
  }

  struct RecordedCall: Equatable {
    let paneID: PaneID
    let kind: AgentKind?
  }

  struct RecordedBoundCall: Equatable {
    let paneID: PaneID
    let kind: AgentKind
    let assumeUserInputSeen: Bool
  }
}
