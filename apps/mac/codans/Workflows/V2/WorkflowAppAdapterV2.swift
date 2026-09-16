import CodansCore
import CodansIPC
import Foundation

extension AppState {
  var workflowAgentPanesV2: [WorkflowPaneChoice] {
    workflowPanes.filter { agentStateStore?.entries[$0.id] != nil }
  }

  func startWorkflowV2(
    definition: WorkflowDefinitionV2, source: String, title: String,
    inputs: [String: JSONValue], selections: [String: WorkflowRoleSelectionV2]
  ) throws -> UUID {
    var bindings: [String: WorkflowBindingV2] = [:]
    for (key, role) in definition.roles {
      guard let selection = selections[key], selection.source == role.source else {
        throw WorkflowAdapterErrorV2.message("Choose a participant for \(role.label).")
      }
      if role.source == "launch" {
        guard
          let profile = settingsStore.settings.agents.enabledProfiles.first(where: {
            $0.id == selection.profileID
          }),
          let workspace = workflowWorkspaces.first(where: { $0.id == selection.worktreeID })
        else {
          throw WorkflowAdapterErrorV2.message(
            "Choose an enabled profile and terminal location for \(role.label).")
        }
        bindings[key] = WorkflowBindingV2(
          source: role.source, profile: profile, projectID: workspace.projectID,
          worktreeID: workspace.id)
      } else {
        guard let paneID = selection.paneID else {
          throw WorkflowAdapterErrorV2.message("Choose an existing Agent for \(role.label).")
        }
        bindings[key] = try workflowBindingV2(paneID: paneID, source: role.source)
      }
    }
    return try workflowServiceV2.start(
      definition: definition, source: source, title: title, inputs: inputs, bindings: bindings)
  }

  func workflowBindingV2(paneID: PaneID, source: String) throws -> WorkflowBindingV2 {
    guard let state = agentStateStore, let entry = state.entries[paneID],
      let address = hierarchyManager.addressOf(paneID: paneID),
      let generation = state.bindingGenerations[paneID]
    else { throw WorkflowAdapterErrorV2.message("The selected Agent is no longer available.") }
    return WorkflowBindingV2(
      source: source, projectID: address.0, worktreeID: address.1,
      paneID: paneID, agentKind: entry.kind, sessionID: entry.sessionID, generation: generation)
  }

  func workflowBindingIsValidV2(_ binding: WorkflowBindingV2) -> Bool {
    guard let paneID = binding.paneID, let state = agentStateStore,
      let entry = state.entries[paneID], hierarchyManager.addressOf(paneID: paneID) != nil,
      entry.kind == binding.agentKind, state.bindingGenerations[paneID] == binding.generation
    else { return false }
    return binding.sessionID == nil || binding.sessionID == entry.sessionID
  }

  func configureWorkflowV2(hierarchy: HierarchyClient, engine: TerminalEngine) {
    workflowServiceV2.cli = Self.cliInvocation()
    workflowServiceV2.validateBinding = { [weak self] binding in
      self?.workflowBindingIsValidV2(binding) == true
    }
    workflowServiceV2.launch = { [weak self] binding, title in
      guard let self, let selectedProfile = binding.profile, let projectID = binding.projectID,
        let worktreeID = binding.worktreeID
      else { throw WorkflowAdapterErrorV2.message("The launch binding is incomplete.") }
      let profile = WorkflowLaunchProfileV2.isolated(selectedProfile)
      let outcome = try await hierarchy.launchAgent(
        AgentLaunchSpec(
          profile: profile, projectID: projectID, worktreeID: worktreeID,
          target: .newTab, focus: false, tabName: title))
      guard let paneID = outcome.paneID else {
        throw WorkflowAdapterErrorV2.message("Agent launch returned no endpoint.")
      }
      let deadline = ContinuousClock.now + .seconds(60)
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        if self.agentStateStore?.entries[paneID]?.kind == profile.kind,
          let resolved = try? self.workflowBindingV2(paneID: paneID, source: "launch")
        {
          var result = resolved
          result.profile = profile
          return result
        }
        try await Task.sleep(for: .milliseconds(250))
      }
      throw WorkflowAdapterErrorV2.message(
        "The launched Agent was not detected. Inspect its terminal before retrying.")
    }
    workflowServiceV2.send = { [weak self, weak engine] binding, prompt, canDispatch in
      guard let self, let engine, let state = self.agentStateStore,
        let paneID = binding.paneID, let kind = binding.agentKind
      else { throw WorkflowAdapterErrorV2.message("The Agent endpoint is unavailable.") }
      let deadline = ContinuousClock.now + .seconds(120)
      while state.entries[paneID]?.state == .working || state.entries[paneID]?.state == .blocked {
        guard canDispatch(), self.workflowBindingIsValidV2(binding) else {
          throw CancellationError()
        }
        guard ContinuousClock.now < deadline else {
          throw WorkflowAdapterErrorV2.message(
            "The Agent is busy or awaiting input. Resolve it in the terminal before sending this assignment."
          )
        }
        try await Task.sleep(for: .milliseconds(500))
      }
      guard self.workflowBindingIsValidV2(binding), canDispatch() else { throw CancellationError() }
      if kind == .omp,
        let screen = engine.ghosttyRuntime?.surface(for: paneID)?.readText(.active),
        AgentKickoffEcho.hasPendingOmpAttachment(screen)
      {
        throw WorkflowAdapterErrorV2.message(
          "The selected OMP Agent has unsent input. Clear or submit that draft before starting another workflow.")
      }
      let sent = await Self.typeKickoffOnceAgentIsUp(
        paneID: paneID, kind: kind, prompt: prompt, agentState: state, engine: engine,
        canDispatch: { [weak self] in
          canDispatch() && self?.workflowBindingIsValidV2(binding) == true
        })
      if !sent && canDispatch() {
        throw WorkflowAdapterErrorV2.message(
          "Prompt submission is uncertain. Inspect the Agent; this assignment was not retried.")
      }
    }
  }
}

nonisolated enum WorkflowAdapterErrorV2: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let value): value
    }
  }
}

nonisolated enum WorkflowLaunchProfileV2 {
  static func isolated(_ selected: AgentProfile) -> AgentProfile {
    guard selected.kind == .claudeCode else { return selected }
    var effective = selected
    // Agent View dispatches into a shared background pool whose inherited pane
    // identity can belong to another role. Workflow roles need foreground sessions.
    effective.envVars["CLAUDE_CODE_DISABLE_AGENT_VIEW"] = "1"
    return effective
  }
}
