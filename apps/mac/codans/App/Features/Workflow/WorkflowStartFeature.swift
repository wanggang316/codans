import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation

/// The workflow start panel: a draft of the one `WorkflowAdmission.Request`
/// the user is about to make, and nothing else. It binds roles, types the
/// inputs, and lets steps be skipped with their consequence spelled out —
/// then hands the request to the same admission the CLI goes through and
/// closes. No run state ever lives here; once a run exists the engine owns
/// it and the AgentState panel shows it.
@Reducer
struct WorkflowStartFeature {
  typealias PaneChoice = WorkflowStartClient.PaneChoice

  /// The worktree a run would start in, captured once when the panel opens.
  struct Source: Equatable, Sendable {
    let projectID: ProjectID
    let worktreeID: WorktreeID
    let worktreeName: String
    let worktreePath: String
    /// The focused pane, and only when it is an agent pane in this
    /// worktree — a `current` role has nothing else to bind to.
    let paneID: PaneID?
    let paneLabel: String?
    let agent: AgentKind?

    init(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      worktreeName: String,
      worktreePath: String,
      paneID: PaneID? = nil,
      paneLabel: String? = nil,
      agent: AgentKind? = nil
    ) {
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.worktreeName = worktreeName
      self.worktreePath = worktreePath
      self.paneID = paneID
      self.paneLabel = paneLabel
      self.agent = agent
    }
  }

  struct ProfileChoice: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let agent: AgentKind
  }

  /// One role of the definition, with whatever this machine can offer it.
  struct RoleRow: Equatable, Sendable, Identifiable {
    let name: String
    let source: WorkflowRole.Source
    /// `launch` only.
    var profiles: [ProfileChoice] = []
    var profileID: UUID?
    /// `pick` only.
    var panes: [PaneChoice] = []
    var paneID: PaneID?

    var id: String { name }
  }

  /// One typed input. `text` is kept in the spelling `--input` takes so the
  /// panel and the CLI hand admission byte-identical values.
  struct InputRow: Equatable, Sendable, Identifiable {
    let input: WorkflowInput
    var text: String

    var id: String { input.name }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// A step that can be left out, and the steps that would miss its
  /// delivery if it were.
  struct SkipRow: Equatable, Sendable, Identifiable {
    struct Consumer: Equatable, Sendable {
      let id: String
      let title: String
    }

    let stepID: String
    let title: String
    let delivery: String
    let consumers: [Consumer]

    var id: String { stepID }
  }

  /// Shown in place of the form when a repository-scoped file with `run:`
  /// steps has not been trusted yet (D8). Trust is granted here or nowhere.
  struct TrustPrompt: Equatable, Sendable {
    let path: String
    let sha256: String
    let commands: [String]
  }

  @ObservableState
  struct State: Equatable {
    let entry: WorkflowCatalogEntry
    let definition: WorkflowDefinition
    let source: Source
    var roles: [RoleRow]
    var inputs: [InputRow]
    var skippable: [SkipRow]
    var skipped: Set<String> = []
    var trust: TrustPrompt?
    /// Inline admission failure, and its diagnostics for an invalid file.
    var message: String?
    var diagnostics: [String] = []
    var isStarting = false

    var workflowName: String { definition.name }

    /// Nothing to configure — the panel is then a plain confirmation.
    var isEmptyForm: Bool { roles.isEmpty && inputs.isEmpty && skippable.isEmpty }

    /// Builds the draft. `nil` for an entry whose file has errors; the
    /// caller filters those out of the palette, so this is belt and braces.
    static func make(
      entry: WorkflowCatalogEntry,
      source: Source,
      agents: AgentSettings,
      workflows: WorkflowSettings,
      panes: [PaneChoice]
    ) -> State? {
      guard let definition = entry.definition else { return nil }
      var roles: [RoleRow] = []
      for role in definition.roles {
        switch role.source {
        case .current:
          roles.append(RoleRow(name: role.name, source: .current))
        case .launch:
          let candidates = WorkflowAdmission.candidateProfiles(for: role, in: agents)
            .map { ProfileChoice(id: $0.id, name: $0.displayName, agent: $0.kind) }
          let preferred = WorkflowAdmission.preferredProfile(
            for: role, workflowID: entry.id, scope: entry.scope, agents: agents, workflows: workflows)
          roles.append(
            RoleRow(name: role.name, source: .launch, profiles: candidates, profileID: preferred?.id))
        case .pick:
          let offered = panes.filter { role.agents?.contains($0.agent) ?? true }
          roles.append(
            RoleRow(
              name: role.name, source: .pick, panes: offered,
              paneID: offered.count == 1 ? offered[0].id : nil))
        }
      }
      let inputs = definition.inputs.map { input in
        InputRow(input: input, text: Self.initialText(for: input))
      }
      let candidates = definition.flattenedSteps.compactMap { step -> SkipRow? in
        guard let expectation = step.expectation else { return nil }
        let consumers = WorkflowValidator.consumers(of: expectation.delivery, in: definition)
          .filter { $0.id != step.id }
          .map { SkipRow.Consumer(id: $0.id, title: $0.displayName) }
        return SkipRow(
          stepID: step.id, title: step.displayName, delivery: expectation.delivery, consumers: consumers)
      }
      let skippable = Self.offerableSkips(candidates)
      return State(
        entry: entry, definition: definition, source: source, roles: roles, inputs: inputs,
        skippable: skippable)
    }

    /// The steps a user could actually leave out. Admission refuses a skip
    /// whose delivery a remaining step still needs, so a step is offered only
    /// when every consumer of its delivery could be skipped too — a chain
    /// (review → fix) stays, but a delivery a plain `message` step reads
    /// (advisor's reply) can never be skipped and would only be a box that
    /// blocks Run when ticked.
    static func offerableSkips(_ candidates: [SkipRow]) -> [SkipRow] {
      var offerable = Set(candidates.map(\.stepID))
      var changed = true
      while changed {
        changed = false
        for row in candidates where offerable.contains(row.stepID) {
          if row.consumers.contains(where: { !offerable.contains($0.id) }) {
            offerable.remove(row.stepID)
            changed = true
          }
        }
      }
      return candidates.filter { offerable.contains($0.stepID) }
    }

    /// A choice with no default has to start unset so it can be refused;
    /// everything else opens on what the file declares.
    static func initialText(for input: WorkflowInput) -> String {
      if let value = input.defaultValue { return value.interpolatedText ?? "" }
      switch input.kind {
      case .boolean: return "false"
      case .string, .number, .choice: return ""
      }
    }

    /// What checking `row` costs, recomputed against the other checked
    /// steps: the first step that still needs the delivery is where the run
    /// would stop. The producer / consumer relation comes from
    /// `WorkflowValidator`, so the panel states the policy rather than
    /// inventing one.
    func consequence(for row: SkipRow) -> String? {
      guard skipped.contains(row.stepID) else { return nil }
      guard let dependent = row.consumers.first(where: { !skipped.contains($0.id) }) else {
        return "Nothing else needs \"\(row.delivery)\"."
      }
      return "\"\(dependent.title)\" needs \"\(row.delivery)\" — the run would end there."
    }

    /// Why Run is not available yet, in the order the user reads the form.
    /// `nil` means admission is the only thing left that can refuse.
    var validationMessage: String? {
      for row in inputs {
        if row.isBlank {
          if row.input.isRequired { return "\"\(row.input.name)\" is required." }
          continue
        }
        if let problem = Self.problem(with: row) { return problem }
      }
      for row in roles {
        switch row.source {
        case .launch where row.profileID == nil:
          return row.profiles.isEmpty
            ? "No enabled agent profile can play \"\(row.name)\"."
            : "Choose a profile for \"\(row.name)\"."
        case .pick where row.paneID == nil:
          return row.panes.isEmpty
            ? "No free agent pane in \(source.worktreeName) can play \"\(row.name)\"."
            : "Choose a pane for \"\(row.name)\"."
        default:
          continue
        }
      }
      for row in skippable where skipped.contains(row.stepID) {
        if let dependent = row.consumers.first(where: { !skipped.contains($0.id) }) {
          return "\"\(dependent.title)\" needs \"\(row.delivery)\"; \"\(row.title)\" cannot be skipped."
        }
      }
      return nil
    }

    var canRun: Bool { !isStarting && validationMessage == nil }

    /// The same typing admission does, run per keystroke so a number out of
    /// range is caught in the field rather than after the round trip.
    static func problem(with row: InputRow) -> String? {
      do {
        _ = try WorkflowAdmission.parse(row.text, as: row.input)
        return nil
      } catch let error as IPCError {
        return error.displayMessage
      } catch {
        return "\"\(row.input.name)\" is not valid."
      }
    }

    /// The shell commands a repository file would run, for the trust card.
    static func commands(in definition: WorkflowDefinition) -> [String] {
      definition.flattenedSteps.compactMap { step in
        guard case .run(let command) = step.verb else { return nil }
        return command.command.source
      }
    }

    func request() -> WorkflowAdmission.Request {
      var roleOverrides: [String: String] = [:]
      for row in roles {
        switch row.source {
        case .launch:
          if let profileID = row.profileID { roleOverrides[row.name] = profileID.uuidString }
        case .pick:
          if let paneID = row.paneID { roleOverrides[row.name] = paneID.raw.uuidString }
        case .current:
          continue
        }
      }
      var values: [String: String] = [:]
      for row in inputs {
        // A cleared optional string is a deliberate empty value; a blank
        // number / choice means "leave it to the file's default".
        if row.isBlank, row.input.kind != .string { continue }
        values[row.input.name] = row.text
      }
      return WorkflowAdmission.Request(
        workflow: entry.id,
        sourcePaneID: source.paneID,
        worktreeID: source.worktreeID,
        // The GUI is never the agent a `current` role addresses, so the
        // first message is typed rather than handed back as self-initiated.
        callerPaneID: nil,
        roles: roleOverrides,
        inputs: values,
        skip: skipped.sorted())
    }
  }

  enum Action: Equatable {
    case setProfile(role: String, profileID: UUID?)
    case setPane(role: String, paneID: PaneID?)
    case setInput(name: String, text: String)
    case setSkipped(stepID: String, Bool)
    case runTapped
    case trustAndRunTapped
    case cancelTapped
    /// Admission or the engine refused. `code` is the domain code the CLI
    /// branches on, so the panel can single out the one failure it can fix.
    case failed(code: String?, message: String, diagnostics: [String])
    case started(UUID)
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismiss
      /// A run started. The parent closes the panel and reports it.
      case started(runID: UUID, workflowName: String)
    }
  }

  @Dependency(WorkflowStartClient.self) private var client

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setProfile(let role, let profileID):
        guard let index = state.roles.firstIndex(where: { $0.name == role }) else { return .none }
        state.roles[index].profileID = profileID
        state.message = nil
        return .none

      case .setPane(let role, let paneID):
        guard let index = state.roles.firstIndex(where: { $0.name == role }) else { return .none }
        state.roles[index].paneID = paneID
        state.message = nil
        return .none

      case .setInput(let name, let text):
        guard let index = state.inputs.firstIndex(where: { $0.input.name == name }) else { return .none }
        state.inputs[index].text = text
        state.message = nil
        return .none

      case .setSkipped(let stepID, let isSkipped):
        guard state.skippable.contains(where: { $0.stepID == stepID }) else { return .none }
        if isSkipped {
          state.skipped.insert(stepID)
        } else {
          state.skipped.remove(stepID)
        }
        state.message = nil
        return .none

      case .runTapped:
        guard !state.isStarting else { return .none }
        if let problem = state.validationMessage {
          state.message = problem
          state.diagnostics = []
          return .none
        }
        state.isStarting = true
        state.message = nil
        state.diagnostics = []
        let request = state.request()
        let client = self.client
        return .run { send in
          do {
            let admitted = try await client.admit(request)
            let runID = try await client.start(admitted.configuration, admitted.entry)
            await send(.started(runID))
          } catch let error as IPCError {
            let hint: [String]
            if case .domain(_, _, let text) = error, let text {
              hint = text.split(separator: "\n").map(String.init)
            } else {
              hint = []
            }
            await send(
              .failed(code: Self.domainCode(error), message: error.displayMessage, diagnostics: hint))
          } catch {
            await send(.failed(code: nil, message: error.localizedDescription, diagnostics: []))
          }
        }

      case .trustAndRunTapped:
        guard let trust = state.trust else { return .none }
        state.trust = nil
        let client = self.client
        return .run { send in
          await client.trust(trust.path, trust.sha256)
          await send(.runTapped)
        }

      case .failed(let code, let message, let diagnostics):
        state.isStarting = false
        // The one refusal the panel can lift: show what the file would run
        // and let the user agree to it, right here.
        if code == "WORKFLOW_TRUST_REQUIRED" {
          state.trust = TrustPrompt(
            path: state.entry.path,
            sha256: state.entry.sha256,
            commands: State.commands(in: state.definition))
          state.message = nil
          state.diagnostics = []
          return .none
        }
        state.message = message
        state.diagnostics = diagnostics
        return .none

      case .started(let runID):
        state.isStarting = false
        return .send(.delegate(.started(runID: runID, workflowName: state.definition.name)))

      case .cancelTapped:
        return .send(.delegate(.dismiss))

      case .delegate:
        return .none
      }
    }
  }

  private static func domainCode(_ error: IPCError) -> String? {
    if case .domain(let code, _, _) = error { return code }
    return nil
  }
}
