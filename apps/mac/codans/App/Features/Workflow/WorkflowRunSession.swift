import CodansCore
import Foundation

/// One run as the engine holds it: the pure machine, the run directory
/// store, the definition it started from, and the timers the engine
/// spawned on its behalf. `run` mirrors the machine after every
/// transition so SwiftUI can observe a value instead of the reducer.
@MainActor
@Observable
final class WorkflowRunSession {
  let entry: WorkflowCatalogEntry
  let store: WorkflowRunStore
  @ObservationIgnored var machine: WorkflowMachine
  /// Snapshot of `machine.run`, refreshed by the engine after each apply.
  private(set) var run: WorkflowRunState

  /// The serial effect chain: every job awaits the one before it, so an
  /// instruction file is on disk before the line pointing at it is typed
  /// and record writes never reorder.
  @ObservationIgnored var queueTail: Task<Void, Never>?
  /// Bumped on every enqueue so a caller can tell whether awaiting the
  /// tail left the queue empty or more work arrived meanwhile.
  @ObservationIgnored var queueGeneration = 0
  /// Log lines drained from transitions and not yet appended to `log.md`.
  @ObservationIgnored var pendingLog: [String] = []
  @ObservationIgnored var roleWaits: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var watchdogs: [Int: Task<Void, Never>] = [:]
  @ObservationIgnored var launchTask: Task<Void, Never>?
  @ObservationIgnored var commandTask: Task<Void, Never>?

  init(entry: WorkflowCatalogEntry, store: WorkflowRunStore, machine: WorkflowMachine) {
    self.entry = entry
    self.store = store
    self.machine = machine
    self.run = machine.run
  }

  // Explicit: a synthesized deinit on a MainActor-isolated class is itself
  // isolated, and hopping actors during dealloc trips libmalloc under
  // SwiftUI teardown. `Task.cancel()` is nonisolated, so this is sound.
  deinit {
    queueTail?.cancel()
    launchTask?.cancel()
    commandTask?.cancel()
    for task in roleWaits.values { task.cancel() }
    for task in watchdogs.values { task.cancel() }
  }

  var id: UUID { run.id }
  var name: String { run.definition.name }

  func refresh() {
    run = machine.run
  }

  func cancelTimers() {
    for task in roleWaits.values { task.cancel() }
    roleWaits = [:]
    for task in watchdogs.values { task.cancel() }
    watchdogs = [:]
    launchTask?.cancel()
    launchTask = nil
    commandTask?.cancel()
    commandTask = nil
  }

  // MARK: - Display

  var currentStepName: String? {
    run.currentStep?.displayName
  }

  var stateName: String { run.status.stateName }

  var attention: WorkflowAttention? { run.status.attention }

  /// The pane a user most likely wants to see for this run: the pane of
  /// the role being waited on, else the initiator.
  var focusPaneID: PaneID? {
    if let activation = run.currentActivation, let paneID = activation.paneID { return paneID }
    if let role = run.currentStep?.role, let paneID = run.paneID(for: role) { return paneID }
    return run.configuration.initiatorPaneID ?? run.bindings.values.compactMap(\.paneID).first
  }

  func elapsed(at now: Date) -> TimeInterval {
    (run.finishedAt ?? now).timeIntervalSince(run.configuration.startedAt)
  }
}
