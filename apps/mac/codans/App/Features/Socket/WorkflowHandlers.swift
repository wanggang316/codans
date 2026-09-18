import CodansCore
import CodansIPC
import Foundation
import os

/// Server-side handler for the `workflow.*` IPC surface: admission, the
/// engine and the activation registry behind closures, plus caller-pane
/// attribution from the socket peer. Owns no run state itself.
@MainActor
final class WorkflowHandlers {
  typealias CallerPaneResolver = @MainActor (pid_t) -> PaneID?

  private let settings: SettingsStore
  private let engine: WorkflowEngine
  private let registry: WorkflowActivationRegistry
  private let admission: WorkflowAdmission
  private let discovery: WorkflowDiscovery
  private let catalog: @MainActor () -> Catalog
  private let addressOf: @MainActor (PaneID) -> PaneAddress?
  private let callerPaneResolver: CallerPaneResolver
  /// Pane → `p<n>` handle, refreshed against the catalog on each call.
  let paneHandles: @MainActor () -> [PaneID: Int]
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "workflow")

  init(
    settings: SettingsStore,
    engine: WorkflowEngine,
    registry: WorkflowActivationRegistry,
    admission: WorkflowAdmission,
    discovery: WorkflowDiscovery,
    catalog: @escaping @MainActor () -> Catalog,
    addressOf: @escaping @MainActor (PaneID) -> PaneAddress?,
    callerPaneResolver: @escaping CallerPaneResolver = { _ in nil },
    paneHandles: @escaping @MainActor () -> [PaneID: Int] = { [:] }
  ) {
    self.settings = settings
    self.engine = engine
    self.registry = registry
    self.admission = admission
    self.discovery = discovery
    self.catalog = catalog
    self.addressOf = addressOf
    self.callerPaneResolver = callerPaneResolver
    self.paneHandles = paneHandles
  }

  // MARK: - list

  func list(_ request: IPC.WorkflowListRequest, peerPID: pid_t?) throws -> IPC.WorkflowListResponse {
    try checkEnabled()
    let worktreeID = request.worktreeID ?? worktree(of: request.paneID ?? callerPane(nil, peerPID: peerPID))
    let root = worktreeID.flatMap(worktreeRoot)
    let workflows = discovery.catalog(worktreeRoot: root).map {
      workflowSummary($0, settings: settings.settings.workflows)
    }
    return IPC.WorkflowListResponse(workflows: workflows)
  }

  // MARK: - run

  func run(_ request: IPC.WorkflowRunRequest, peerPID: pid_t?) async throws -> IPC.WorkflowRunResponse {
    try checkEnabled()
    var sourcePaneID = request.sourcePaneID
    if sourcePaneID == nil, request.worktreeID == nil {
      sourcePaneID = callerPane(nil, peerPID: peerPID)
    }
    let admitted = try admission.admit(
      WorkflowAdmission.Request(
        workflow: request.workflow,
        sourcePaneID: sourcePaneID,
        worktreeID: request.worktreeID,
        roles: request.roles,
        inputs: request.inputs,
        skip: request.skip))
    let started: (runID: UUID, selfInitiated: WorkflowSelfInitiatedTask?)
    do {
      started = try await engine.start(configuration: admitted.configuration, entry: admitted.entry)
    } catch {
      logger.error("run start failed: \(String(describing: error), privacy: .public)")
      throw IPCError.internal("could not start the run: \(error)")
    }
    let configuration = admitted.configuration
    let bindings = engine.run(for: started.runID)?.bindings ?? configuration.bindings
    return IPC.WorkflowRunResponse(
      runID: started.runID,
      workflowID: configuration.definition.id,
      workflowName: configuration.definition.name,
      runDirectory: configuration.runDirectory,
      bindings: bindingSummaries(bindings, definition: configuration.definition),
      selfInitiated: started.selfInitiated.flatMap(selfInitiatedSummary))
  }

  // MARK: - status

  func status(_ request: IPC.WorkflowStatusRequest, peerPID: pid_t?) throws -> IPC.WorkflowStatusResponse {
    try checkEnabled()
    let caller = callerPane(request.callerPaneID, peerPID: peerPID)
    if let runID = request.runID {
      if let session = engine.session(for: runID) {
        return IPC.WorkflowStatusResponse(run: summary(session, callerPaneID: caller), participant: nil)
      }
      guard let record = recordOnDisk(runID: runID, near: caller) else {
        throw IPCError.domain(code: "RUN_NOT_FOUND", message: "no run \(runID.uuidString)", hint: nil)
      }
      return IPC.WorkflowStatusResponse(run: summary(record), participant: nil)
    }
    guard let caller, let runID = registry.runID(forPane: caller), let session = engine.session(for: runID) else {
      throw IPCError.domain(
        code: "RUN_NOT_FOUND", message: "the calling pane takes part in no run", hint: "pass a run id")
    }
    let role = session.run.bindings.first { $0.value.paneID == caller }?.key ?? ""
    return IPC.WorkflowStatusResponse(
      run: summary(session, callerPaneID: caller),
      participant: IPC.WorkflowParticipantSummary(role: role, paneID: caller))
  }

  // MARK: - deliver

  func deliver(_ request: IPC.WorkflowDeliverRequest, peerPID: pid_t?) async throws -> IPC.WorkflowDeliverResponse {
    try checkEnabled()
    let caller = callerPane(request.callerPaneID, peerPID: peerPID)
    let target = try deliveryTarget(request, caller: caller)
    let result = await engine.deliver(
      runID: target.runID, ordinal: target.ordinal, token: request.token, allowManual: target.manual,
      force: request.force, body: request.body, verdict: request.verdict)
    switch result.outcome {
    case .rejected(let code, let message):
      throw IPCError.domain(code: code, message: message, hint: nil)
    case .accepted, .provisional:
      guard let delivery = result.delivery, let run = engine.run(for: target.runID),
        let activation = run.activations[target.ordinal]
      else {
        throw IPCError.internal("the delivery was accepted but could not be written")
      }
      let issues: [String]
      if case .provisional(let list) = result.outcome { issues = list } else { issues = [] }
      return IPC.WorkflowDeliverResponse(
        runID: target.runID,
        stepID: activation.stepID,
        delivery: delivery.name,
        ordinal: target.ordinal,
        state: issues.isEmpty ? "delivered" : "provisional",
        path: delivery.path,
        issues: issues)
    }
  }

  private struct DeliveryTarget {
    let runID: UUID
    let ordinal: Int
    let manual: Bool
  }

  /// Explicit `--run --step` → that step's current activation (manual);
  /// otherwise the token, then the caller's pane, name the activation.
  private func deliveryTarget(_ request: IPC.WorkflowDeliverRequest, caller: PaneID?) throws -> DeliveryTarget {
    if let runID = request.runID, let stepID = request.stepID {
      guard let run = engine.run(for: runID), engine.session(for: runID).map({ !$0.run.status.isTerminal }) == true
      else {
        throw IPCError.domain(code: "RUN_NOT_FOUND", message: "no active run \(runID.uuidString)", hint: nil)
      }
      guard let activation = run.currentActivation, activation.stepID == stepID else {
        throw IPCError.domain(
          code: "STEP_NOT_EXPECTING", message: "step \(stepID) is not waiting for a delivery", hint: nil)
      }
      try checkRoleMatch(caller: caller, runID: runID, paneID: activation.paneID, force: request.force)
      return DeliveryTarget(runID: runID, ordinal: activation.ordinal, manual: true)
    }
    if let caller, let entry = registry.activation(forPane: caller) {
      return DeliveryTarget(runID: entry.runID, ordinal: entry.ordinal, manual: false)
    }
    if let token = request.token {
      guard let entry = registry.activation(forToken: token) else {
        throw IPCError.domain(code: "TOKEN_INVALID", message: "no waiting step matches this token", hint: nil)
      }
      try checkRoleMatch(caller: caller, runID: entry.runID, paneID: entry.paneID, force: request.force)
      return DeliveryTarget(runID: entry.runID, ordinal: entry.ordinal, manual: false)
    }
    if let caller, registry.runID(forPane: caller) != nil {
      throw IPCError.domain(
        code: "STEP_NOT_EXPECTING", message: "no step is waiting on the calling pane", hint: nil)
    }
    throw IPCError.domain(
      code: "TOKEN_REQUIRED",
      message: "no run is waiting on this pane",
      hint: "set CODANS_WORKFLOW_TOKEN, or pass --run and --step")
  }

  /// A pane delivering for a step that belongs to another pane (or another
  /// run) is a mix-up unless the caller said `--force`.
  private func checkRoleMatch(caller: PaneID?, runID: UUID, paneID: PaneID?, force: Bool) throws {
    guard let caller, !force else { return }
    let mismatch = (paneID != nil && paneID != caller) || registry.runID(forPane: caller).map { $0 != runID } == true
    if mismatch {
      throw IPCError.domain(
        code: "ROLE_MISMATCH",
        message: "the calling pane is not the one this step waits on",
        hint: "pass --force to deliver on its behalf")
    }
  }

  // MARK: - resolve / cancel

  func resolve(_ request: IPC.WorkflowResolveRequest, peerPID: pid_t?) throws -> IPC.WorkflowStatusResponse {
    try checkEnabled()
    guard let action = WorkflowUserAction(rawValue: request.action) else {
      throw IPCError.invalidParams(message: "unknown action \"\(request.action)\"", path: ["action"])
    }
    guard let session = engine.session(for: request.runID), !session.run.status.isTerminal else {
      throw IPCError.domain(code: "RUN_NOT_FOUND", message: "no active run \(request.runID.uuidString)", hint: nil)
    }
    if action != .cancel, action != .focusPane {
      guard let attention = session.run.status.attention, attention.actions.contains(action) else {
        throw IPCError.conflict(reason: "the run does not offer \"\(request.action)\" right now")
      }
    }
    engine.resolve(runID: request.runID, action: action, verdict: request.verdict)
    return IPC.WorkflowStatusResponse(
      run: summary(session, callerPaneID: callerPane(nil, peerPID: peerPID)), participant: nil)
  }

  func cancel(_ request: IPC.WorkflowCancelRequest, peerPID: pid_t?) throws -> IPC.WorkflowStatusResponse {
    try checkEnabled()
    guard let session = engine.session(for: request.runID), !session.run.status.isTerminal else {
      throw IPCError.domain(code: "RUN_NOT_FOUND", message: "no active run \(request.runID.uuidString)", hint: nil)
    }
    engine.cancel(runID: request.runID)
    return IPC.WorkflowStatusResponse(
      run: summary(session, callerPaneID: callerPane(nil, peerPID: peerPID)), participant: nil)
  }

  // MARK: - listRuns

  func listRuns(_ request: IPC.WorkflowListRunsRequest, peerPID: pid_t?) throws -> IPC.WorkflowRunListResponse {
    try checkEnabled()
    guard let worktreeID = request.worktreeID ?? worktree(of: request.paneID ?? callerPane(nil, peerPID: peerPID))
    else {
      throw IPCError.invalidParams(message: "no worktree: run from inside a pane or pass --worktree", path: nil)
    }
    guard let root = worktreeRoot(worktreeID) else {
      throw IPCError.notFound(kind: "worktree", id: worktreeID.description)
    }
    var runs: [UUID: IPC.WorkflowRunSummary] = [:]
    if let index = try? WorkflowRunIndex.load(worktreeRoot: root) {
      for entry in index.runs {
        runs[entry.id] = summary(entry, worktreeID: worktreeID, worktreeRoot: root)
      }
    }
    for session in engine.activeRuns + engine.finishedRuns
    where session.run.configuration.source.worktreeID == worktreeID {
      runs[session.id] = summary(session, callerPaneID: nil)
    }
    var sorted = runs.values.sorted { $0.startedAt > $1.startedAt }
    if let limit = request.limit, limit > 0 {
      sorted = Array(sorted.prefix(limit))
    }
    return IPC.WorkflowRunListResponse(runs: sorted)
  }

  // MARK: - Helpers

  private func checkEnabled() throws {
    guard settings.settings.workflows.isEnabled else {
      throw IPCError.unsupported(reason: "workflows are turned off in Settings")
    }
  }

  private func callerPane(_ explicit: PaneID?, peerPID: pid_t?) -> PaneID? {
    if let explicit { return explicit }
    guard let peerPID else { return nil }
    return callerPaneResolver(peerPID)
  }

  private func worktree(of paneID: PaneID?) -> WorktreeID? {
    paneID.flatMap(addressOf)?.worktreeID
  }

  private func worktreeRoot(_ worktreeID: WorktreeID) -> URL? {
    for project in catalog().projects {
      if let worktree = project.worktrees.first(where: { $0.id == worktreeID }) {
        return project.isRemote ? nil : URL(fileURLWithPath: worktree.path, isDirectory: true)
      }
    }
    return nil
  }

  /// A run this app no longer holds: the caller's worktree first, then
  /// every local worktree in the catalog.
  private func recordOnDisk(runID: UUID, near caller: PaneID?) -> WorkflowRunRecord? {
    var roots: [URL] = []
    if let worktreeID = worktree(of: caller), let root = worktreeRoot(worktreeID) {
      roots.append(root)
    }
    for project in catalog().projects where !project.isRemote {
      roots += project.worktrees.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }
    for root in roots {
      let store = WorkflowRunStore(worktreeRoot: root, runID: runID)
      if let record = try? store.readRecord() { return record }
    }
    return nil
  }
}
