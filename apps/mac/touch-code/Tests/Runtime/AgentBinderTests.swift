import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Behavioural coverage for `AgentBinder`. Foreground job snapshots are
/// authoritative; title and desktop-notification strings are weak
/// fallbacks that only fill an empty binding.
@MainActor
struct AgentBinderTests {
  @Test
  func paneCreatedDoesNotBindFromInitialCommand() {
    let f = Fixture(initialCommand: "claude")
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func foregroundJobBindsDirectAgentProcess() {
    let f = Fixture(initialCommand: nil)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex --resume"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  @Test
  func foregroundJobRebindsAlreadyBoundPane() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  @Test
  func foregroundJobClearsWhenNoAgentProcessRemains() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .codex)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "-zsh", commandLine: "-zsh"))
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: nil)])
  }

  @Test
  func titleChangedFillsMissingBindingFromCodexTitle() {
    let f = Fixture(initialCommand: nil)
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value.isEmpty)

    f.title.setValue("Codex CLI v1.2")
    f.binder.consider(paneID: f.paneID, trigger: .titleChanged)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  @Test
  func titleChangedDoesNotRewriteAlreadyBoundPane() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.title.setValue("Codex CLI")
    f.binder.consider(paneID: f.paneID, trigger: .titleChanged)
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func promptReturnedDoesNotRewriteAlreadyBoundPane() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.title.setValue("Codex CLI")
    f.binder.consider(paneID: f.paneID, trigger: .promptReturned)
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func unbindAlwaysCallsThroughWithNil() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.binder.unbind(f.paneID)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: nil)])
  }

  @Test
  func paneCreatedWithNoMatchingSignalsIsSilent() {
    let f = Fixture(initialCommand: nil)
    f.title.setValue("bash (idle)")
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value.isEmpty)
  }

  // MARK: - Extra coverage for sticky/rebind edges

  @Test
  func desktopNotificationBindsFromTriggerPayload() {
    let f = Fixture(initialCommand: nil)
    // Live title intentionally non-matching to prove the binder uses
    // the trigger payload, not the title closure.
    f.title.setValue("bash")
    f.binder.consider(
      paneID: f.paneID,
      trigger: .desktopNotification(title: "Claude", body: "ready")
    )
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .claudeCode)])
  }

  @Test
  func promptReturnedFillsMissingBindingOnly() {
    let f = Fixture(initialCommand: nil)
    f.title.setValue("Codex CLI")
    f.binder.consider(paneID: f.paneID, trigger: .promptReturned)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  @Test
  func foregroundJobWithSameKindIsNoOp() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .codex)
    f.binder.consider(
      paneID: f.paneID,
      trigger: .foregroundJobChanged(Self.job(argv0: "codex", commandLine: "codex"))
    )
    #expect(f.calls.value.isEmpty)
  }

  @Test
  func promptReturnedWithNoSignalsDoesNotUnbind() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.title.setValue("bash")
    f.binder.consider(paneID: f.paneID, trigger: .promptReturned)
    #expect(f.calls.value.isEmpty)
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

  // MARK: - Fixture

  /// Reusable harness: records every `setPaneAgentKind` call into a
  /// shared `LockIsolated` log and exposes a mutable `title` so a single
  /// test can sequence a paneCreated → title-change → prompt-end story
  /// against one binder instance.
  @MainActor
  final class Fixture {
    let paneID = PaneID()
    let calls = LockIsolated<[RecordedCall]>([])
    let title = LockIsolated<String?>(nil)
    let initialCommand: LockIsolated<String?>
    let agentKind: LockIsolated<AgentKind?>
    let binder: AgentBinder

    init(initialCommand: String? = nil, initialAgentKind: AgentKind? = nil) {
      self.initialCommand = LockIsolated(initialCommand)
      self.agentKind = LockIsolated(initialAgentKind)

      var hierarchyClient = HierarchyClient.testValue
      let calls = self.calls
      let agentKind = self.agentKind
      hierarchyClient.setPaneAgentKind = { paneID, kind in
        calls.withValue { $0.append(RecordedCall(paneID: paneID, kind: kind)) }
        // Mirror the write into the fixture's `agentKind` box so the
        // binder's next `currentAgentKind` read reflects the prior
        // write — same observable behaviour as the live manager.
        agentKind.setValue(kind)
      }

      let initialCommandBox = self.initialCommand
      let titleBox = self.title
      self.binder = AgentBinder(
        client: hierarchyClient,
        currentAgentKind: { _ in agentKind.value },
        paneInitialCommand: { _ in initialCommandBox.value },
        paneTitle: { _ in titleBox.value }
      )
    }
  }

  /// One recorded `setPaneAgentKind` invocation.
  struct RecordedCall: Equatable {
    let paneID: PaneID
    let kind: AgentKind?
  }
}
