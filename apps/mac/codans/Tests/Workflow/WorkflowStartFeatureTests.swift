import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The workflow start panel as a draft: what it prefills from the file and
/// this machine's settings, what it refuses to submit, what it says a skip
/// would cost, and how it turns an admission refusal into something the
/// user can act on.
@MainActor
struct WorkflowStartFeatureTests {
  // MARK: - Fixtures

  static let reviewLoop = """
    name: Review Loop
    description: Iterate until the review is clean.
    inputs:
      focus:
        type: string
        required: true
      max-rounds:
        type: number
        default: 3
        min: 1
        max: 5
    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [claude-code]
        profile: Reviewer
    steps:
      - id: review
        launch: reviewer
        prompt: Review ${{ inputs.focus }}.
        expect: {delivery: review}
      - id: fix
        message: author
        instruction: Address ${{ deliveries.review.path }}.
        expect: {delivery: fixes}
      - id: done
        notify: Done within ${{ inputs.max-rounds }} rounds.
    """

  static let repoCheck = """
    name: Check
    roles:
      author:
        source: current
    steps:
      - id: build
        run: make build
      - id: ask
        message: author
        text: Look at the build output.
        expect: {delivery: notes}
    """

  static let reviewerProfile = AgentProfile(kind: .claudeCode, name: "Reviewer")
  static let buildProfile = AgentProfile(kind: .codex, name: "Build")

  static func entry(
    _ yaml: String, id: String, scope: WorkflowScope = .user, path: String? = nil
  ) throws -> WorkflowCatalogEntry {
    let parsed = WorkflowDocumentParser.parse(yaml: yaml, id: id)
    let definition = try #require(parsed.definition)
    let diagnostics = parsed.diagnostics + WorkflowValidator.validate(definition)
    #expect(!diagnostics.hasErrors, "\(diagnostics)")
    return WorkflowCatalogEntry(
      id: id, scope: scope, path: path ?? "/tmp/\(id).workflow.yaml", yaml: yaml, sha256: "sha-\(id)",
      definition: definition, diagnostics: diagnostics)
  }

  static let source = WorkflowStartFeature.Source(
    projectID: ProjectID(raw: UUID()),
    worktreeID: WorktreeID(raw: UUID()),
    worktreeName: "feat-workflow",
    worktreePath: "/repo",
    paneID: PaneID(),
    paneLabel: "p1 · dev · Claude Code",
    agent: .claudeCode
  )

  static func makeState(
    _ yaml: String = reviewLoop,
    id: String = "review-loop",
    scope: WorkflowScope = .user,
    profiles: [AgentProfile] = [reviewerProfile, buildProfile],
    workflows: WorkflowSettings = .default,
    panes: [WorkflowStartClient.PaneChoice] = []
  ) throws -> WorkflowStartFeature.State {
    let entry = try entry(yaml, id: id, scope: scope)
    return try #require(
      WorkflowStartFeature.State.make(
        entry: entry, source: source, agents: AgentSettings(profiles: profiles),
        workflows: workflows, panes: panes))
  }

  // MARK: - Prefill

  /// A `launch` role opens on the profile the file names; only profiles the
  /// role's `agents` allow are offered at all. Inputs open on their
  /// defaults, and every step with an `expect` can be left out.
  @Test
  func prefillsTheDeclaredProfileTheDefaultsAndEverySkippableStep() throws {
    let state = try Self.makeState()

    #expect(state.roles.map(\.name) == ["author", "reviewer"])
    let author = try #require(state.roles.first { $0.name == "author" })
    #expect(author.source == .current)
    let reviewer = try #require(state.roles.first { $0.name == "reviewer" })
    #expect(reviewer.profiles.map(\.name) == ["Reviewer"])
    #expect(reviewer.profileID == Self.reviewerProfile.id)

    #expect(state.inputs.map(\.input.name) == ["focus", "max-rounds"])
    #expect(state.inputs.first { $0.input.name == "focus" }?.text == "")
    #expect(state.inputs.first { $0.input.name == "max-rounds" }?.text == "3")

    #expect(state.skippable.map(\.stepID) == ["review", "fix"])
  }

  /// A remembered binding outranks the file's `profile:` name, and it is
  /// keyed by the role's requirements — the same order admission walks.
  @Test
  func aRememberedBindingWinsOverTheFilesProfileName() throws {
    let role = WorkflowRole(name: "reviewer", source: .launch, agents: [.claudeCode], profile: "Reviewer")
    let other = AgentProfile(kind: .claudeCode, name: "Second Opinion")
    var workflows = WorkflowSettings.default
    workflows.remember(
      WorkflowBindingMemory(
        scope: .user, workflowID: "review-loop", role: "reviewer",
        requirementsDigest: WorkflowAdmission.requirementsDigest(for: role),
        profileID: other.id))

    let state = try Self.makeState(profiles: [Self.reviewerProfile, other], workflows: workflows)
    #expect(state.roles.first { $0.name == "reviewer" }?.profileID == other.id)
  }

  /// A `pick` role lists the agent panes it was handed; the only candidate
  /// is selected for the user, more than one is a question.
  @Test
  func aPickRoleOffersTheWorktreesAgentPanes() throws {
    let yaml = """
      name: Advisor
      roles:
        advisor:
          source: pick
      steps:
        - id: ask
          message: advisor
          text: What do you think?
          expect: {delivery: opinion}
      """
    let pane = WorkflowStartClient.PaneChoice(id: PaneID(), label: "p2 · dev", agent: .claudeCode)
    let second = WorkflowStartClient.PaneChoice(id: PaneID(), label: "p3 · dev", agent: .codex)

    let ambiguous = try Self.makeState(yaml, id: "advisor", panes: [pane, second])
    #expect(ambiguous.roles.first?.panes.map(\.id) == [pane.id, second.id])
    #expect(ambiguous.roles.first?.paneID == nil)
    #expect(ambiguous.validationMessage == "Choose a pane for \"advisor\".")

    let single = try Self.makeState(yaml, id: "advisor", panes: [pane])
    #expect(single.roles.first?.paneID == pane.id)
    #expect(single.validationMessage == nil)
  }

  // MARK: - Gating

  /// A required input with nothing in it blocks Run and says so, without
  /// ever reaching admission — the client's `admit` is unimplemented, so a
  /// call would fail this test.
  @Test
  func aRequiredInputBlocksRunWithAnInlineHint() async throws {
    let state = try Self.makeState()
    #expect(state.validationMessage == "\"focus\" is required.")
    #expect(state.canRun == false)

    let store = TestStore(initialState: state) { WorkflowStartFeature() }
    await store.send(.runTapped) {
      $0.message = "\"focus\" is required."
    }

    await store.send(.setInput(name: "focus", text: "the parser")) {
      $0.inputs[0].text = "the parser"
      $0.message = nil
    }
    #expect(store.state.validationMessage == nil)
  }

  /// Numbers are typed against the file's own range, in the field, with the
  /// same parser admission uses.
  @Test
  func aNumberOutsideItsRangeIsCaughtInTheField() async throws {
    var state = try Self.makeState()
    state.inputs[0].text = "the parser"
    let store = TestStore(initialState: state) { WorkflowStartFeature() }

    await store.send(.setInput(name: "max-rounds", text: "9")) {
      $0.inputs[1].text = "9"
    }
    #expect(store.state.validationMessage == "input \"max-rounds\" must be at most 5")

    await store.send(.setInput(name: "max-rounds", text: "2")) {
      $0.inputs[1].text = "2"
    }
    #expect(store.state.validationMessage == nil)
  }

  // MARK: - Skips

  /// Ticking a step says immediately which step would then miss the
  /// delivery and end the run; unticking every consumer clears it.
  @Test
  func skippingAStepNamesTheDependentThatWouldEndTheRun() async throws {
    var state = try Self.makeState()
    state.inputs[0].text = "the parser"
    let store = TestStore(initialState: state) { WorkflowStartFeature() }
    let review = try #require(state.skippable.first { $0.stepID == "review" })
    let fix = try #require(state.skippable.first { $0.stepID == "fix" })

    await store.send(.setSkipped(stepID: "review", true)) {
      $0.skipped = ["review"]
    }
    #expect(
      store.state.consequence(for: review) == "\"fix\" needs \"review\" — the run would end there.")
    #expect(
      store.state.validationMessage == "\"fix\" needs \"review\"; \"review\" cannot be skipped.")

    // With its only consumer skipped too, the delivery is owed to nobody.
    await store.send(.setSkipped(stepID: "fix", true)) {
      $0.skipped = ["review", "fix"]
    }
    #expect(store.state.consequence(for: review) == "Nothing else needs \"review\".")
    #expect(store.state.consequence(for: fix) == "Nothing else needs \"fixes\".")
    #expect(store.state.validationMessage == nil)
  }

  /// A delivery a non-skippable step reads can never be skipped, so the
  /// panel does not offer it at all — advisor shows no Steps section.
  @Test
  func aStepWhoseDeliveryAMessageReadsIsNotOffered() throws {
    let yaml = """
      name: Advisor
      roles:
        asker: {source: current}
        advisor: {source: launch, agents: [claude-code]}
      steps:
        - id: ask
          launch: advisor
          prompt: Help.
          expect: {delivery: advice}
        - id: reply
          message: asker
          text: Read ${{ deliveries.advice.path }}.
      """
    let state = try Self.makeState(yaml, id: "advisor")
    #expect(state.skippable.isEmpty)
  }

  // MARK: - GUI entry points

  private static func rootStore(
    selection: HierarchySelection = .empty,
    addressOf: @escaping @MainActor @Sendable (PaneID) -> PaneAddress? = { _ in nil }
  ) -> TestStoreOf<RootFeature> {
    var state = RootFeature.State()
    state.selection = selection
    let store = TestStore(initialState: state) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.addressOf = addressOf
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.editorClient = EditorClient.testValue
      $0.gitService = GitServiceClient.testValue
    }
    store.exhaustivity = .off
    return store
  }

  /// A pick from the toolbar's Run Workflow menu opens the start panel for
  /// the worktree selected at that moment, with no pinned source pane.
  @Test
  @MainActor
  func theToolbarMenuStartsInTheSelectedWorktree() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let store = Self.rootStore(selection: HierarchySelection(projectID: projectID, worktreeID: worktreeID))

    await store.send(.worktreeHeader(.delegate(.runWorkflowRequested(workflowID: "advisor"))))
    await store.receive(
      .workflowStartRequested(projectID, worktreeID, workflowID: "advisor", sourcePaneID: nil))
  }

  /// A pick from an Agents View row's menu pins that row's pane as the
  /// source, in the worktree the pane lives in.
  @Test
  @MainActor
  func anAgentRowMenuStartsWithThatPaneAsTheSource() async {
    let address = PaneAddress(projectID: ProjectID(), worktreeID: WorktreeID(), tabID: TabID(), paneID: PaneID())
    let store = Self.rootStore(addressOf: { $0 == address.paneID ? address : nil })

    await store.send(.agentState(.runWorkflowTapped(address.paneID, workflowID: "advisor")))
    await store.receive(
      .workflowStartRequested(
        address.projectID, address.worktreeID, workflowID: "advisor", sourcePaneID: address.paneID))
  }

  // MARK: - Admission

  /// Admission's domain code is what the panel reports, verbatim, so the
  /// user reads the same refusal the CLI would print.
  @Test
  func anAdmissionRefusalBecomesAnInlineMessage() async throws {
    var state = try Self.makeState()
    state.inputs[0].text = "the parser"
    let store = TestStore(initialState: state) {
      WorkflowStartFeature()
    } withDependencies: {
      $0[WorkflowStartClient.self].admit = { _ in
        throw IPCError.domain(
          code: "PANE_BUSY", message: "pane p1 already takes part in run 42", hint: nil)
      }
    }

    await store.send(.runTapped) { $0.isStarting = true }
    await store.receive(
      .failed(code: "PANE_BUSY", message: "pane p1 already takes part in run 42", diagnostics: [])
    ) {
      $0.isStarting = false
      $0.message = "pane p1 already takes part in run 42"
    }
  }

  /// The request the panel hands admission is the one the form describes:
  /// the worktree, the focused agent pane, the chosen profile by id, the
  /// typed inputs, and the ticked steps. The GUI is never the initiator.
  @Test
  func theRequestCarriesTheWholeForm() throws {
    var state = try Self.makeState()
    state.inputs[0].text = "the parser"
    state.skipped = ["fix"]
    let request = state.request()

    #expect(request.workflow == "review-loop")
    #expect(request.worktreeID == Self.source.worktreeID)
    #expect(request.sourcePaneID == Self.source.paneID)
    #expect(request.callerPaneID == nil)
    #expect(request.roles == ["reviewer": Self.reviewerProfile.id.uuidString])
    #expect(request.inputs == ["focus": "the parser", "max-rounds": "3"])
    #expect(request.skip == ["fix"])
  }

  /// A worktree with no agent pane in focus leaves the `current` row empty
  /// and hands admission no pane, which is what makes it say
  /// SOURCE_REQUIRED rather than the panel guessing one.
  @Test
  func withoutAFocusedAgentPaneTheRequestNamesOnlyTheWorktree() async throws {
    let entry = try Self.entry(Self.reviewLoop, id: "review-loop")
    var state = try #require(
      WorkflowStartFeature.State.make(
        entry: entry,
        source: WorkflowStartFeature.Source(
          projectID: Self.source.projectID, worktreeID: Self.source.worktreeID,
          worktreeName: "feat-workflow", worktreePath: "/repo"),
        agents: AgentSettings(profiles: [Self.reviewerProfile]),
        workflows: .default, panes: []))
    state.inputs[0].text = "the parser"
    #expect(state.source.paneLabel == nil)
    #expect(state.request().sourcePaneID == nil)

    let store = TestStore(initialState: state) {
      WorkflowStartFeature()
    } withDependencies: {
      $0[WorkflowStartClient.self].admit = { _ in
        throw IPCError.domain(
          code: "SOURCE_REQUIRED", message: "run from inside a pane", hint: nil)
      }
    }
    await store.send(.runTapped) { $0.isStarting = true }
    await store.receive(
      .failed(code: "SOURCE_REQUIRED", message: "run from inside a pane", diagnostics: [])
    ) {
      $0.isStarting = false
      $0.message = "run from inside a pane"
    }
  }

  // MARK: - Trust

  /// A repository file with `run:` steps is refused until the user agrees to
  /// it here. The panel shows the path and the commands, and "Trust and Run"
  /// grants and admits again — trust is never implicit.
  @Test
  func trustRequiredShowsTheCommandsAndTrustAndRunGrantsThenAdmitsAgain() async throws {
    let entry = try Self.entry(
      Self.repoCheck, id: "check", scope: .repo, path: "/repo/.codans/workflows/check.workflow.yaml")
    let state = try #require(
      WorkflowStartFeature.State.make(
        entry: entry, source: Self.source, agents: AgentSettings(profiles: [Self.reviewerProfile]),
        workflows: .default, panes: []))
    let runID = UUID()
    let world = World(entry: entry, runID: runID)

    let store = TestStore(initialState: state) {
      WorkflowStartFeature()
    } withDependencies: {
      $0[WorkflowStartClient.self].admit = { request in try world.admit(request) }
      $0[WorkflowStartClient.self].start = { configuration, _ in configuration.id }
      $0[WorkflowStartClient.self].trust = { path, sha in world.granted.append(Grant(path: path, sha256: sha)) }
    }

    await store.send(.runTapped) { $0.isStarting = true }
    await store.receive(
      .failed(
        code: "WORKFLOW_TRUST_REQUIRED",
        message: "workflow check runs shell commands from the repository and is not trusted yet",
        diagnostics: ["trust it under Settings"])
    ) {
      $0.isStarting = false
      $0.trust = WorkflowStartFeature.TrustPrompt(
        path: "/repo/.codans/workflows/check.workflow.yaml",
        sha256: "sha-check",
        commands: ["make build"])
    }

    await store.send(.trustAndRunTapped) { $0.trust = nil }
    await store.receive(.runTapped) { $0.isStarting = true }
    await store.receive(.started(runID)) { $0.isStarting = false }
    await store.receive(.delegate(.started(runID: runID, workflowName: "Check")))

    #expect(world.granted == [Grant(path: entry.path, sha256: "sha-check")])
  }

  // MARK: - Helpers

  struct Grant: Equatable {
    let path: String
    let sha256: String
  }

  /// Admission that refuses once for trust and accepts afterwards.
  @MainActor
  final class World {
    let entry: WorkflowCatalogEntry
    let runID: UUID
    var granted: [Grant] = []

    init(entry: WorkflowCatalogEntry, runID: UUID) {
      self.entry = entry
      self.runID = runID
    }

    func admit(_ request: WorkflowAdmission.Request) throws -> WorkflowAdmission.Admitted {
      guard !granted.isEmpty else {
        throw IPCError.domain(
          code: "WORKFLOW_TRUST_REQUIRED",
          message: "workflow check runs shell commands from the repository and is not trusted yet",
          hint: "trust it under Settings")
      }
      return WorkflowAdmission.Admitted(
        configuration: WorkflowRunConfiguration(
          id: runID,
          definition: entry.definition!,
          source: WorkflowRunSource(
            projectID: WorkflowStartFeatureTests.source.projectID,
            worktreeID: WorkflowStartFeatureTests.source.worktreeID,
            worktreePath: "/repo",
            worktreeName: "feat-workflow"),
          bindings: [:],
          runDirectory: "/repo/.codans/workflow-runs/\(runID.uuidString)",
          cliCommand: "codans",
          startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        entry: entry)
    }
  }
}
