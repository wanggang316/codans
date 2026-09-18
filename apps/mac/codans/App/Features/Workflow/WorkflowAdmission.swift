import CodansCore
import CodansIPC
import CryptoKit
import Foundation

/// Turns a `workflow.run` request into a `WorkflowRunConfiguration`
/// without touching any pane: resolve the definition, the source
/// worktree, trust, inputs, skips and role bindings, in that order, and
/// refuse with a stable domain code at the first thing that is missing.
/// The GUI start panel and the CLI both come through here.
@MainActor
struct WorkflowAdmission {
  struct Request {
    var workflow: String
    var sourcePaneID: PaneID?
    var worktreeID: WorktreeID?
    /// The pane the request came from, when it came from one. Only this
    /// pane can be the run's initiator: a run started from elsewhere
    /// against a `[source]` pane must have its first message typed, not
    /// handed back to a caller that is not the agent.
    var callerPaneID: PaneID?
    var roles: [String: String] = [:]
    var inputs: [String: String] = [:]
    var skip: [String] = []
  }

  /// What admission reads from the app, as closures.
  struct Context {
    var discovery: WorkflowDiscovery
    var settings: @MainActor () -> Settings
    var catalog: @MainActor () -> Catalog
    var addressOf: @MainActor (PaneID) -> PaneAddress?
    /// Resolves `p<n>`, a pane UUID, or `@label` to a pane.
    var resolvePane: @MainActor (String) -> PaneID?
    var agentKind: @MainActor (PaneID) -> AgentKind?
    /// The run a pane already belongs to.
    var runID: @MainActor (PaneID) -> UUID?
    var cliCommand: String
    var now: @MainActor () -> Date = { Date() }
  }

  struct Admitted {
    let configuration: WorkflowRunConfiguration
    let entry: WorkflowCatalogEntry
  }

  /// The worktree a run is scoped to.
  struct Source {
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let path: String
    let name: String
    let branch: String?
    let isRemote: Bool
    let paneID: PaneID?
  }

  let context: Context

  func admit(_ request: Request) throws -> Admitted {
    let source = try resolveSource(request)
    let entry = try resolveDefinition(request.workflow, worktreeRoot: source.map { URL(fileURLWithPath: $0.path) })
    guard let definition = entry.definition else {
      throw IPCError.domain(code: "WORKFLOW_INVALID", message: "workflow \(entry.id) has errors", hint: nil)
    }
    guard let source else {
      throw IPCError.domain(
        code: "SOURCE_REQUIRED",
        message: "no source: run from inside a pane, or name a pane or worktree",
        hint: nil)
    }
    if source.isRemote {
      throw IPCError.unsupported(reason: "workflows write .codans/workflow-runs/ under the worktree, which is remote")
    }
    try checkTrust(entry)
    let inputs = try typedInputs(request.inputs, definition: definition)
    let skipped = try validatedSkips(request.skip, definition: definition)
    let bindings = try resolveBindings(request.roles, definition: definition, source: source, skipped: skipped)
    let runID = UUID()
    let configuration = WorkflowRunConfiguration(
      id: runID,
      definition: definition,
      source: WorkflowRunSource(
        projectID: source.projectID, worktreeID: source.worktreeID, worktreePath: source.path,
        worktreeName: source.name, branch: source.branch),
      bindings: bindings,
      inputs: inputs,
      skippedSteps: skipped,
      runDirectory: WorkflowRunLayout.runDirectory(
        worktreeRoot: URL(fileURLWithPath: source.path, isDirectory: true), runID: runID
      ).path(percentEncoded: false),
      cliCommand: context.cliCommand,
      initiatorPaneID: request.callerPaneID,
      startedAt: context.now()
    )
    return Admitted(configuration: configuration, entry: entry)
  }

  // MARK: - Definition

  private func resolveDefinition(_ reference: String, worktreeRoot: URL?) throws -> WorkflowCatalogEntry {
    guard let entry = context.discovery.resolve(reference, worktreeRoot: worktreeRoot) else {
      throw IPCError.domain(code: "WORKFLOW_NOT_FOUND", message: "no workflow named \"\(reference)\"", hint: nil)
    }
    if !entry.isValid {
      let lines = entry.diagnostics.map { "\($0.severity.rawValue): \($0.message)" }
      throw IPCError.domain(
        code: "WORKFLOW_INVALID",
        message: "workflow \(entry.id) has \(entry.diagnostics.filter(\.isError).count) error(s)",
        hint: lines.joined(separator: "\n"))
    }
    if context.settings().workflows.isDisabled(entry.id) {
      throw IPCError.domain(
        code: "WORKFLOW_DISABLED", message: "workflow \(entry.id) is disabled in Settings", hint: nil)
    }
    return entry
  }

  private func checkTrust(_ entry: WorkflowCatalogEntry) throws {
    guard entry.requiresTrust, !context.settings().workflows.isTrusted(path: entry.path, sha256: entry.sha256)
    else { return }
    throw IPCError.domain(
      code: "WORKFLOW_TRUST_REQUIRED",
      message: "workflow \(entry.id) runs shell commands from the repository and is not trusted yet",
      hint: "trust it under Settings → Agents → Workflows")
  }

  // MARK: - Source

  private func resolveSource(_ request: Request) throws -> Source? {
    if let paneID = request.sourcePaneID {
      guard let address = context.addressOf(paneID) else {
        throw IPCError.notFound(kind: "pane", id: paneID.description)
      }
      return source(worktreeID: address.worktreeID, paneID: paneID)
    }
    if let worktreeID = request.worktreeID {
      guard let source = source(worktreeID: worktreeID, paneID: nil) else {
        throw IPCError.notFound(kind: "worktree", id: worktreeID.description)
      }
      return source
    }
    return nil
  }

  private func source(worktreeID: WorktreeID, paneID: PaneID?) -> Source? {
    for project in context.catalog().projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { continue }
      return Source(
        projectID: project.id, worktreeID: worktree.id, path: worktree.path, name: worktree.name,
        branch: worktree.branch, isRemote: project.isRemote, paneID: paneID)
    }
    return nil
  }

  // MARK: - Inputs

  private func typedInputs(_ raw: [String: String], definition: WorkflowDefinition) throws -> [String: WorkflowValue] {
    for name in raw.keys where definition.input(named: name) == nil {
      throw IPCError.invalidParams(message: "workflow has no input named \"\(name)\"", path: ["inputs", name])
    }
    var typed: [String: WorkflowValue] = [:]
    for input in definition.inputs {
      if let text = raw[input.name] {
        typed[input.name] = try Self.parse(text, as: input)
      } else if let defaultValue = input.defaultValue {
        typed[input.name] = defaultValue
      } else if input.isRequired {
        throw IPCError.domain(
          code: "INPUT_REQUIRED", message: "input \"\(input.name)\" is required",
          hint: "pass --input \(input.name)=<\(input.kind.rawValue)>")
      }
    }
    return typed
  }

  static func parse(_ text: String, as input: WorkflowInput) throws -> WorkflowValue {
    let path = ["inputs", input.name]
    switch input.kind {
    case .string:
      guard !text.contains("\n") else {
        throw IPCError.invalidParams(message: "input \"\(input.name)\" must be a single line", path: path)
      }
      return .string(text)
    case .number:
      guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
        throw IPCError.invalidParams(message: "input \"\(input.name)\" must be an integer", path: path)
      }
      if let min = input.min, value < min {
        throw IPCError.invalidParams(message: "input \"\(input.name)\" must be at least \(min)", path: path)
      }
      if let max = input.max, value > max {
        throw IPCError.invalidParams(message: "input \"\(input.name)\" must be at most \(max)", path: path)
      }
      return .int(value)
    case .boolean:
      switch text.trimmingCharacters(in: .whitespaces).lowercased() {
      case "true": return .bool(true)
      case "false": return .bool(false)
      default:
        throw IPCError.invalidParams(message: "input \"\(input.name)\" must be true or false", path: path)
      }
    case .choice:
      guard input.options.contains(text) else {
        throw IPCError.invalidParams(
          message: "input \"\(input.name)\" must be one of: \(input.options.joined(separator: ", "))", path: path)
      }
      return .string(text)
    }
  }

  // MARK: - Skips

  /// Only a step whose delivery nothing requires may be skipped up front;
  /// otherwise the dependent step would fail on a missing reference.
  private func validatedSkips(_ skip: [String], definition: WorkflowDefinition) throws -> Set<String> {
    var skipped: Set<String> = []
    for stepID in skip {
      guard let step = definition.step(id: stepID) else {
        throw IPCError.invalidParams(message: "no step with id \"\(stepID)\"", path: ["skip"])
      }
      if let expectation = step.expectation {
        let consumers = WorkflowValidator.consumers(of: expectation.delivery, in: definition)
          .filter { $0.id != stepID && !skip.contains($0.id) }
        if let dependent = consumers.first {
          throw IPCError.invalidParams(
            message: "step \"\(stepID)\" cannot be skipped: \"\(dependent.id)\" needs its delivery",
            path: ["skip"])
        }
      }
      skipped.insert(stepID)
    }
    return skipped
  }

  // MARK: - Roles

  private func resolveBindings(
    _ overrides: [String: String],
    definition: WorkflowDefinition,
    source: Source,
    skipped: Set<String>
  ) throws -> [String: WorkflowRoleBinding] {
    for name in overrides.keys where definition.role(named: name) == nil {
      throw IPCError.invalidParams(message: "workflow has no role named \"\(name)\"", path: ["roles", name])
    }
    var bindings: [String: WorkflowRoleBinding] = [:]
    var claimed: Set<PaneID> = []
    for role in definition.roles {
      switch role.source {
      case .current:
        let paneID = try currentPane(for: role, definition: definition, source: source, skipped: skipped)
        try claim(paneID, for: role, claimed: &claimed)
        bindings[role.name] = .current(paneID: paneID)
      case .pick:
        let paneID = try pickedPane(for: role, override: overrides[role.name], source: source)
        try claim(paneID, for: role, claimed: &claimed)
        bindings[role.name] = .pick(paneID: paneID)
      case .launch:
        let profile = try launchProfile(for: role, override: overrides[role.name], workflowID: definition.id)
        bindings[role.name] = .launch(
          profileID: profile.id, profileName: profile.displayName, agent: profile.kind, paneID: nil)
      }
    }
    return bindings
  }

  private func claim(_ paneID: PaneID, for role: WorkflowRole, claimed: inout Set<PaneID>) throws {
    if let other = context.runID(paneID) {
      throw IPCError.domain(
        code: "PANE_BUSY", message: "pane \(paneID) already takes part in run \(other.uuidString)", hint: nil)
    }
    guard claimed.insert(paneID).inserted else {
      throw IPCError.invalidParams(message: "pane \(paneID) is bound to two roles", path: ["roles", role.name])
    }
  }

  /// The `current` role needs an agent in the pane only when a step that
  /// is not skipped will type into it; a bare shell can still start a run.
  private func currentPane(
    for role: WorkflowRole, definition: WorkflowDefinition, source: Source, skipped: Set<String>
  ) throws -> PaneID {
    guard let paneID = source.paneID else {
      throw IPCError.domain(
        code: "SOURCE_REQUIRED", message: "role \"\(role.name)\" is the calling pane; run from inside a pane",
        hint: nil)
    }
    let messaged = definition.flattenedSteps.contains { step in
      if case .message(let target, _, _) = step.verb { return target == role.name && !skipped.contains(step.id) }
      return false
    }
    if messaged, context.agentKind(paneID) == nil {
      throw IPCError.domain(
        code: "SOURCE_REQUIRED", message: "the calling pane has no recognized agent for role \"\(role.name)\"",
        hint: nil)
    }
    return paneID
  }

  private func pickedPane(for role: WorkflowRole, override: String?, source: Source) throws -> PaneID {
    guard let reference = override, !reference.isEmpty else {
      throw IPCError.invalidParams(
        message: "role \"\(role.name)\" needs a pane: --role \(role.name)=<p<n>|uuid|@label>",
        path: ["roles", role.name])
    }
    guard let paneID = context.resolvePane(reference), let address = context.addressOf(paneID) else {
      throw IPCError.invalidParams(message: "no pane matches \"\(reference)\"", path: ["roles", role.name])
    }
    guard address.worktreeID == source.worktreeID else {
      throw IPCError.invalidParams(
        message: "pane \(reference) is not in the source worktree", path: ["roles", role.name])
    }
    guard let kind = context.agentKind(paneID) else {
      throw IPCError.invalidParams(message: "pane \(reference) has no recognized agent", path: ["roles", role.name])
    }
    if let allowed = role.agents, !allowed.contains(kind) {
      throw IPCError.invalidParams(
        message: "pane \(reference) runs \(kind.rawValue); role \"\(role.name)\" wants \(Self.list(allowed))",
        path: ["roles", role.name])
    }
    return paneID
  }

  /// Override → remembered binding → the definition's `profile:` → the
  /// single qualifying profile → `PROFILE_REQUIRED`.
  private func launchProfile(for role: WorkflowRole, override: String?, workflowID: String) throws -> AgentProfile {
    let agents = context.settings().agents
    if let override, !override.isEmpty, override.lowercased() != "auto" {
      let profile = try AgentProfileSelector.resolve(selector: override, agent: nil, in: agents)
      guard Self.qualifies(profile, for: role) else {
        throw IPCError.invalidParams(
          message: "profile \"\(profile.displayName)\" cannot play \"\(role.name)\" (\(Self.requirement(role)))",
          path: ["roles", role.name])
      }
      return profile
    }
    let scope = context.discovery.resolve(workflowID, worktreeRoot: nil)?.scope
    if let scope,
      let memory = context.settings().workflows.binding(
        scope: scope, workflowID: workflowID, role: role.name, digest: Self.requirementsDigest(for: role)),
      let profile = agents.profile(id: memory.profileID), Self.qualifies(profile, for: role)
    {
      return profile
    }
    if let name = role.profile,
      let profile = agents.enabledProfiles.first(where: { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
      ),
      Self.qualifies(profile, for: role)
    {
      return profile
    }
    let candidates = agents.enabledProfiles.filter { Self.qualifies($0, for: role) }
    if candidates.count == 1 { return candidates[0] }
    throw IPCError.domain(
      code: "PROFILE_REQUIRED",
      message: candidates.isEmpty
        ? "no enabled profile can play \"\(role.name)\" (\(Self.requirement(role)))"
        : "\(candidates.count) profiles can play \"\(role.name)\"; choose one",
      hint: "pass --role \(role.name)=<profile name or id>")
  }

  static func qualifies(_ profile: AgentProfile, for role: WorkflowRole) -> Bool {
    guard profile.isEnabled, profile.descriptor.supportsInitialPrompt else { return false }
    if let allowed = role.agents { return allowed.contains(profile.kind) }
    return true
  }

  private static func requirement(_ role: WorkflowRole) -> String {
    role.agents.map { "agents: \(list($0))" } ?? "any agent that accepts a prompt"
  }

  private static func list(_ kinds: [AgentKind]) -> String {
    kinds.map(\.rawValue).joined(separator: ", ")
  }

  // MARK: - Digest

  private nonisolated struct Requirements: Encodable, Sendable {
    let agents: [String]?
    let profile: String?
    let source: String
  }

  /// SHA-256 of the role's requirement block as canonical JSON. Editing
  /// what a role asks for invalidates a remembered binding; editing its
  /// prompt does not.
  nonisolated static func requirementsDigest(for role: WorkflowRole) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let requirements = Requirements(
      agents: role.agents?.map(\.rawValue).sorted(), profile: role.profile, source: role.source.rawValue)
    let data = (try? encoder.encode(requirements)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
