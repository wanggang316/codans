import CodansCore
import Foundation

/// Pure, view-independent projections of a `WorkflowRunState` for the
/// AgentState panel's workflow popover: step status, role/pane pairing,
/// attention action labels, and skip-consequence text. Kept outside
/// `WorkflowRunSession` (a `@MainActor` class) so this logic is testable
/// without actor isolation, and deliberately dumb — every status here is
/// read straight off the run record and cursor, never re-derived policy
/// (the machine already decided it; see `docs/design-docs/workflow.md`).
nonisolated enum WorkflowRunDisplay {
  enum StepStatus: Equatable {
    case done
    case current
    case pending
    case skipped
    case failed
  }

  struct StepRow: Equatable, Identifiable {
    var id: String
    var name: String
    var status: StepStatus
  }

  /// One row per step, document order with loop bodies inlined after
  /// their loop (`WorkflowDefinition.flattenedSteps`). A step that has
  /// run gets its status from `run.steps[id].outcome`; the step the
  /// cursor is on right now is `current`, but only while the run is
  /// still alive — a finished run's `currentStepID` is history, not a
  /// live cursor position.
  static func stepRows(for run: WorkflowRunState) -> [StepRow] {
    run.definition.flattenedSteps.map { step in
      StepRow(id: step.id, name: step.displayName, status: status(ofStep: step.id, in: run))
    }
  }

  private static func status(ofStep stepID: String, in run: WorkflowRunState) -> StepStatus {
    if let outcome = run.steps[stepID]?.outcome {
      switch outcome {
      case .success: return .done
      case .failure: return .failed
      case .skipped: return .skipped
      }
    }
    if !run.status.isTerminal, stepID == run.currentStepID { return .current }
    return .pending
  }

  struct RoleRow: Equatable, Identifiable {
    var id: String
    var name: String
    var paneID: PaneID?
    /// Last agent state the engine observed for this role
    /// (`idle`/`working`/`blocked`/`finished`/`gone`), `nil` before the
    /// first observation.
    var state: String?
  }

  /// One row per declared role, in definition order.
  static func roleRows(for run: WorkflowRunState) -> [RoleRow] {
    run.definition.roles.map { role in
      RoleRow(
        id: role.name, name: role.name, paneID: run.bindings[role.name]?.paneID,
        state: run.roleStates[role.name])
    }
  }

  /// The verdicts offered for "Accept with Verdict…" — the current
  /// activation's declared set, or empty when the step has none (in
  /// which case the action itself would not appear in `attention.actions`).
  static func verdictOptions(for run: WorkflowRunState) -> [String] {
    run.currentActivation?.expectation.verdicts ?? []
  }

  /// The confirmation text for Skip, or `nil` when skipping the current
  /// step has no consequence and needs no confirmation — either it has
  /// no `expect` at all (mirrors `performSkip`'s own guard), or nothing
  /// downstream requires its delivery. Reads `skipConsequence` straight
  /// off the machine — this does not decide whether the run would end,
  /// only how to say so.
  static func skipConfirmationMessage(machine: WorkflowMachine) -> String? {
    guard let delivery = machine.run.currentStep?.expectation?.delivery,
      let dependentID = machine.skipConsequence(forDelivery: delivery)
    else { return nil }
    let dependentName = machine.run.definition.step(id: dependentID)?.displayName ?? dependentID
    return
      "This ends the run: \"\(dependentName)\" still needs this delivery and has no fallback for its absence."
  }
}

nonisolated extension WorkflowUserAction {
  /// Button label from the design doc's attention action table
  /// ("`expect`：显式交付"). The popover renders `attention.actions` in
  /// the order the machine gives them; this only supplies text.
  var displayLabel: String {
    switch self {
    case .accept: return "Accept"
    case .acceptWithVerdict: return "Accept with Verdict…"
    case .askAgain: return "Ask Again"
    case .keepWaiting: return "Keep Waiting"
    case .skip: return "Skip"
    case .cancel: return "Cancel"
    case .relaunch: return "Relaunch"
    case .retry: return "Retry"
    case .focusPane: return "Focus Pane"
    }
  }

  /// Stable suffix for `agentState.workflow.<action>` accessibility
  /// identifiers — the action's own raw value, already kebab-free camelCase
  /// apart from `accept-with-verdict` and friends, so map explicitly.
  var accessibilitySuffix: String {
    switch self {
    case .accept: return "accept"
    case .acceptWithVerdict: return "acceptWithVerdict"
    case .askAgain: return "askAgain"
    case .keepWaiting: return "keepWaiting"
    case .skip: return "skip"
    case .cancel: return "cancel"
    case .relaunch: return "relaunch"
    case .retry: return "retry"
    case .focusPane: return "focusPane"
    }
  }
}
