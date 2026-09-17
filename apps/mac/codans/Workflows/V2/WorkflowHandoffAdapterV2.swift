import CodansCore
import CodansIPC
import Foundation
import Yams

extension AppState {
  /// Original Handoff entry points specialize the bundled definition, then freeze
  /// it through the same service used by Run Workflow.
  func startHandoffWorkflowV2(
    source: HandoffSource, profile: AgentProfile?, placement: HandoffPlacement,
    briefing: String? = nil, contextOnly: Bool = false, saveOnly: Bool = false, transitionOnly: Bool = false,
    note: String = ""
  ) throws -> (UUID, String) {
    guard !source.isRemote else {
      throw WorkflowAdapterErrorV2.message("Handoff context requires a local worktree.")
    }
    workflowCatalogV2.reload()
    guard
      let entry = workflowCatalogV2.entries.first(where: {
        $0.isBuiltin && $0.definition?.id == "codans.handoff"
      }), var definition = entry.definition
    else {
      throw WorkflowAdapterErrorV2.message("The built-in Handoff workflow is unavailable.")
    }
    var bindings: [String: WorkflowBindingV2] = [:]
    var inputs: [String: JSONValue] = ["note": .string(note)]
    if briefing != nil || contextOnly {
      definition.nodes.removeValue(forKey: "briefing")
      definition.roles.removeValue(forKey: "author")
      definition.inputs["briefing"] = .init(type: "string", required: true)
      inputs["briefing"] = .string(briefing ?? "")
      definition.nodes["context"]?.needs = []
      definition.nodes["context"]?.arguments?["briefing"] = .object(["ref": .string("inputs.briefing")])
    } else {
      bindings["author"] = try workflowBindingV2(paneID: source.paneID, source: "current")
    }
    if saveOnly || transitionOnly {
      definition.name = saveOnly ? "Save Progress" : "Prepare Handoff"
      definition.id = saveOnly ? "codans.handoff.checkpoint" : "codans.handoff.prepare"
      for key in ["launch_receiver", "receive", "verify", "resume"] {
        definition.nodes.removeValue(forKey: key)
      }
      definition.roles.removeValue(forKey: "receiver")
      if saveOnly {
        definition.nodes["context"]?.arguments?["mode"] = .object(["value": .string("checkpoint")])
        definition.nodes["briefing"]?.arguments?["instruction"] = .object([
          "value": .string(
            "Save a progress checkpoint from this conversation. Infer the objective; preserve constraints, completed work and concrete next steps. Use level-two Markdown headings: Objective, Current State, Completed Work, Next Steps. Submit through delivery. This only saves progress; it does not transfer ownership or instruct you to abandon the task."
          )
        ])
      } else if let profile {
        definition.nodes["context"]?.arguments?["receiver"] = .object(["value": .string(profile.kind.rawValue)])
      }
      definition.outputs = ["packet": .object(["ref": .string("nodes.packet.outputs.packet")])]
    } else {
      guard let profile, profile.isEnabled else {
        throw WorkflowAdapterErrorV2.message("Choose an enabled receiving Agent profile.")
      }
      bindings["receiver"] = .init(
        source: "launch", profile: profile, projectID: source.projectID, worktreeID: source.worktreeID,
        target: placement.target, direction: placement.direction, anchorPaneID: source.paneID)
    }
    let yaml = try YAMLEncoder().encode(definition)
    let id = try workflowServiceV2.start(
      definition: definition, source: yaml, title: definition.name, inputs: inputs, bindings: bindings,
      origin: .init(projectID: source.projectID, worktreeID: source.worktreeID, paneID: source.paneID))
    return (id, try workflowServiceV2.inspectionDirectory(for: id).path)
  }

  func configureHandoffWorkflowV2(engine: TerminalEngine, git: GitServiceClient) {
    workflowServiceV2.saveHandoffContext = { [weak self, weak engine] run, arguments in
      guard let self,
        let paneID = run.bindings["author"]?.paneID ?? run.origin?.paneID,
        let source = Self.handoffSource(for: paneID, manager: self.hierarchyManager, agentState: self.agentStateStore),
        !source.isRemote
      else { throw WorkflowAdapterErrorV2.message("The Handoff source is no longer available.") }
      guard let text = arguments["briefing"]?.v2String,
        let mode = arguments["mode"]?.v2String, ["checkpoint", "transition"].contains(mode)
      else { throw WorkflowAdapterErrorV2.message("Invalid Handoff context inputs.") }
      let prepared =
        try text.isEmpty ? HandoffPreparedBriefing.contextOnly : HandoffPreparedBriefing(source: .inline(text))
      let coordinator = HandoffCoordinator(store: HandoffStore(rootURL: URL(fileURLWithPath: source.worktreePath)))
      try coordinator.store.ensureLayout()
      let session = HandoffSessionContext(
        agentKind: source.agentKind, sessionID: source.sessionID, paneID: source.paneID.description,
        paneTitle: source.paneTitle, screenExcerpt: engine?.ghosttyRuntime?.surface(for: paneID)?.readText(.viewport))
      let repo = await Self.handoffRepoState(at: coordinator.store.rootURL, git: git)
      // Cancellation during repository collection must not write a new checkpoint.
      guard self.workflowServiceV2.run(run.id)?.status == "running" else { throw CancellationError() }
      let now = Date()
      var archive: String?
      if mode == "checkpoint" {
        _ = try coordinator.checkpoint(
          outgoing: source.agentKind, session: session, repo: repo, briefing: prepared,
          note: run.inputs["note"]?.v2String, now: now)
      } else {
        guard
          let receiver = run.bindings["receiver"]?.profile?.kind
            ?? arguments["receiver"]?.v2String.flatMap({ AgentKind(token: $0) })
        else {
          throw WorkflowAdapterErrorV2.message("Missing Handoff receiver.")
        }
        let transition = try coordinator.transition(
          outgoing: source.agentKind, to: receiver, session: session, repo: repo, briefing: prepared, now: now)
        archive = transition.archivedPath
        try coordinator.store.appendLog(
          "workflow=\(run.id.uuidString) context saved; inspect workflow for receiver status", now: now)
      }
      let context = try String(contentsOf: coordinator.store.contextURL, encoding: .utf8)
      let combined =
        (text.isEmpty
          ? "# Context-only handoff\nNo source-authored briefing was supplied." : (prepared.artifact ?? text))
        + "\n\n# Repository and Session Context\n\n" + context
        + "\n\nWorktree: \(source.worktreePath)\n"
        + "\n\n# Additional Handoff Instructions\n\n" + (run.inputs["note"]?.v2String ?? "")
      var artifacts: [String: JSONValue] = ["contextPath": .string(coordinator.store.contextURL.path)]
      if !text.isEmpty { artifacts["briefingPath"] = .string(coordinator.store.currentURL.path) }
      if let archive { artifacts["archivedPath"] = .string(archive) }
      return ["briefing": .string(combined), "artifacts": .object(artifacts)]
    }
  }
}
