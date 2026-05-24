import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Behavioural coverage for `AgentBinder`. The binder is the only writer
/// to `Pane.agentKind` outside of catalog-decode paths, so these tests
/// pin down the sticky-rule contract from the design doc:
///
/// - `.paneCreated` is the only trigger that can write a nil classify
///   result (records "no signal yet").
/// - `.titleChanged` / `.desktopNotification` only fill in a missing
///   binding; they never rewrite an already-bound pane.
/// - `.promptReturned` is the single rebind path.
/// - `unbind(_:)` is the only path that clears the field.
///
/// The shared fixture records every `setPaneAgentKind` call (paneID,
/// kind) into a `LockIsolated` array. Asserting on the full call log —
/// rather than just the "current value" — is what catches a sticky-rule
/// regression that would silently double-write or skip a write.
@MainActor
struct AgentBinderTests {
  /// (a) Pane created with `initialCommand="claude"` → exactly one
  /// `setPaneAgentKind(paneID, .claudeCode)` call.
  @Test
  func paneCreatedWithClaudeInitialCommandBindsToClaudeCode() {
    let f = Fixture(initialCommand: "claude")
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .claudeCode)])
  }

  /// (b) Pane created with no initialCommand; later titleChanged to
  /// `"Codex CLI v1.2"` → one call with `.codex`.
  @Test
  func titleChangedFillsMissingBindingFromCodexTitle() {
    let f = Fixture(initialCommand: nil)
    // paneCreated with no signals writes nil (records "no match yet").
    // That is itself a write per the design-doc rule but the existing
    // value is also nil, so writeIfChanged short-circuits.
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value.isEmpty)

    // Title arrives with a Codex banner.
    f.title.setValue("Codex CLI v1.2")
    f.binder.consider(paneID: f.paneID, trigger: .titleChanged)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  /// (c) Already bound `.claudeCode` pane; `titleChanged` to `"Codex CLI"`
  /// (no prompt-end) → no calls (sticky binding).
  @Test
  func titleChangedDoesNotRewriteAlreadyBoundPane() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.title.setValue("Codex CLI")
    f.binder.consider(paneID: f.paneID, trigger: .titleChanged)
    #expect(f.calls.value.isEmpty)
  }

  /// (d) Continuing (c), then `.promptReturned` → one call with `.codex`
  /// (rebind). The classifier sees the live Codex title and the binder's
  /// prompt-end branch is the only one allowed to overwrite an existing
  /// binding.
  @Test
  func promptReturnedRebindsToCodexWhenTitleChanged() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.title.setValue("Codex CLI")
    f.binder.consider(paneID: f.paneID, trigger: .promptReturned)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: .codex)])
  }

  /// (e) `unbind(paneID)` for any state → one call with `nil`. The
  /// underlying writer is already idempotent, so the binder is allowed
  /// to call through unconditionally; we assert exactly that contract.
  @Test
  func unbindAlwaysCallsThroughWithNil() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.binder.unbind(f.paneID)
    #expect(f.calls.value == [.init(paneID: f.paneID, kind: nil)])
  }

  /// (f) Pane created with title `"bash (idle)"` (matches nothing) →
  /// no calls. The existing value is nil, the classify result is nil,
  /// `writeIfChanged` skips so logs/traces stay clean.
  @Test
  func paneCreatedWithNoMatchingSignalsIsSilent() {
    let f = Fixture(initialCommand: nil)
    f.title.setValue("bash (idle)")
    f.binder.consider(paneID: f.paneID, trigger: .paneCreated)
    #expect(f.calls.value.isEmpty)
  }

  // MARK: - Extra coverage for sticky/rebind edges

  /// `.desktopNotification` carries its own title payload that overrides
  /// the `notificationTitle` channel for that one call — sanity-check
  /// that the binder feeds it through rather than re-reading the live
  /// `paneTitle` closure.
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

  /// `.promptReturned` with a same-kind classify result is a no-op —
  /// rebind path must not churn the writer when the verdict is unchanged.
  @Test
  func promptReturnedWithSameKindIsNoOp() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .codex)
    f.title.setValue("Codex CLI")
    f.binder.consider(paneID: f.paneID, trigger: .promptReturned)
    #expect(f.calls.value.isEmpty)
  }

  /// `.promptReturned` with no matching signals must NOT clear an
  /// existing binding. A quiet prompt does not mean the agent has left.
  @Test
  func promptReturnedWithNoSignalsDoesNotUnbind() {
    let f = Fixture(initialCommand: nil, initialAgentKind: .claudeCode)
    f.title.setValue("bash")
    f.binder.consider(paneID: f.paneID, trigger: .promptReturned)
    #expect(f.calls.value.isEmpty)
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
