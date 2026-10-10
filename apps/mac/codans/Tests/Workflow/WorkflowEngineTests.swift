import CodansCore
import Foundation
import Testing

@testable import Codans

/// The engine against fakes: an injectable clock, a recording terminal,
/// scripted agent state. Pins effect interpretation — typing produces
/// `injected`, deliveries land on disk before the machine advances, idle
/// only counts once held, the watchdog fires after working → idle.
@MainActor
struct WorkflowEngineTests {
  /// Scripted world the engine polls.
  final class World {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var lines: [(PaneID, String)] = []
    var sendSucceeds = true
    var states: [PaneID: AgentStateStore.AgentRuntimeState] = [:]
    var existing: Set<PaneID> = []
    var notifications: [(String, String, PaneID?)] = []
    var remembered: [WorkflowBindingMemory] = []
    var launches: [WorkflowLaunchRequest] = []
    var launchPane = PaneID()

    func advance(_ seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
    }
  }

  struct Harness {
    let engine: WorkflowEngine
    let registry: WorkflowActivationRegistry
    let world: World
    let root: URL
    let paneID: PaneID
  }

  static let yaml = """
    name: Ping
    roles:
      author:
        source: current
    steps:
      - id: ask
        message: author
        text: Summarize the diff.
        expect: {delivery: summary}
      - id: done
        notify: Done ${{ deliveries.summary.path }}
    """

  static let launchYAML = """
    name: Launch
    roles:
      reviewer:
        source: launch
    steps:
      - id: start
        launch: reviewer
        prompt: Review the diff.
        expect: {delivery: review}
    """

  static func makeHarness(yaml: String = yaml, idleHold: TimeInterval = 2) throws -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "WorkflowEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let world = World()
    let paneID = PaneID()
    world.existing = [paneID, world.launchPane]
    world.states[paneID] = .idle
    let registry = WorkflowActivationRegistry()
    var dependencies = WorkflowEngineDependencies(
      sendLine: { paneID, line in
        world.lines.append((paneID, line))
        return world.sendSucceeds
      },
      launch: { request, _, _ in
        world.launches.append(request)
        return world.launchPane
      },
      runCommand: { _, _, _, _ in .exited(code: 0, stdout: Data("ok\n".utf8), stderr: Data(), stdoutOverflow: false) },
      closePane: { _ in },
      focusPane: { _ in },
      paneExists: { world.existing.contains($0) },
      agentState: { world.states[$0] },
      notify: { title, body, paneID in world.notifications.append((title, body, paneID)) },
      profile: { AgentProfile(id: $0, kind: .claudeCode, name: "Reviewer") },
      rememberBinding: { world.remembered.append($0) }
    )
    dependencies.now = { world.now }
    dependencies.makeToken = { "tok-\(UUID().uuidString.prefix(8))" }
    dependencies.idleHoldSeconds = idleHold
    dependencies.pollInterval = .milliseconds(5)
    let engine = WorkflowEngine(registry: registry, dependencies: dependencies)
    return Harness(engine: engine, registry: registry, world: world, root: root, paneID: paneID)
  }

  static func entry(yaml: String, id: String = "ping") throws -> WorkflowCatalogEntry {
    let parsed = WorkflowDocumentParser.parse(yaml: yaml, id: id)
    let definition = try #require(parsed.definition)
    let diagnostics = parsed.diagnostics + WorkflowValidator.validate(definition)
    #expect(!diagnostics.hasErrors, "\(diagnostics)")
    return WorkflowCatalogEntry(
      id: id, scope: .user, path: "/tmp/\(id).workflow.yaml", yaml: yaml, sha256: "x",
      definition: definition, diagnostics: diagnostics)
  }

  /// A configuration whose `current` pane is not the initiator, so the
  /// first message is typed rather than handed back.
  static func configuration(
    _ harness: Harness, entry: WorkflowCatalogEntry, selfInitiated: Bool
  ) throws -> WorkflowRunConfiguration {
    let definition = try #require(entry.definition)
    let id = UUID()
    var bindings: [String: WorkflowRoleBinding] = [:]
    for role in definition.roles {
      switch role.source {
      case .current, .pick: bindings[role.name] = .current(paneID: harness.paneID)
      case .launch:
        bindings[role.name] = .launch(profileID: UUID(), profileName: "Reviewer", agent: .claudeCode, paneID: nil)
      }
    }
    return WorkflowRunConfiguration(
      id: id,
      definition: definition,
      source: WorkflowRunSource(
        projectID: ProjectID(), worktreeID: WorktreeID(), worktreePath: harness.root.path(percentEncoded: false),
        worktreeName: "wt"),
      bindings: bindings,
      runDirectory: WorkflowRunLayout.runDirectory(worktreeRoot: harness.root, runID: id).path(percentEncoded: false),
      cliCommand: "codans",
      initiatorPaneID: selfInitiated ? harness.paneID : nil,
      startedAt: harness.world.now,
      idleGraceSeconds: 10
    )
  }

  /// Yields until `condition` holds or a bounded number of turns pass.
  static func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<400 where !condition() {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: - Injection

  @Test
  func idleRoleGetsTheLineTypedOnlyAfterTheHold() async throws {
    let harness = try Self.makeHarness()
    let entry = try Self.entry(yaml: Self.yaml)
    let configuration = try Self.configuration(harness, entry: entry, selfInitiated: false)
    let started = try await harness.engine.start(configuration: configuration, entry: entry)
    #expect(started.selfInitiated == nil)
    // Idle since the first poll, but the 2 s hold has not passed.
    try await Task.sleep(for: .milliseconds(40))
    #expect(harness.world.lines.isEmpty)
    #expect(harness.engine.run(for: started.runID)?.phase == .waitingForRole(role: "author", ordinal: 1))

    harness.world.advance(2)
    await Self.settle { !harness.world.lines.isEmpty }
    let line = try #require(harness.world.lines.first)
    #expect(line.0 == harness.paneID)
    #expect(line.1.hasPrefix("Summarize the diff."))
    #expect(line.1.contains("codans workflow deliver"))
    await Self.settle { harness.engine.run(for: started.runID)?.phase == .waitingForDelivery(ordinal: 1) }
    #expect(harness.engine.run(for: started.runID)?.phase == .waitingForDelivery(ordinal: 1))
    #expect(harness.registry.activation(forPane: harness.paneID)?.ordinal == 1)
    // The record and log are on disk.
    let store = WorkflowRunStore(runDirectory: URL(fileURLWithPath: configuration.runDirectory))
    #expect(try store.readRecord()?.status == .running)
  }

  @Test
  func failedTypingRaisesAnAttention() async throws {
    let harness = try Self.makeHarness(idleHold: 0)
    harness.world.sendSucceeds = false
    let entry = try Self.entry(yaml: Self.yaml)
    let configuration = try Self.configuration(harness, entry: entry, selfInitiated: false)
    let started = try await harness.engine.start(configuration: configuration, entry: entry)
    await Self.settle { harness.engine.run(for: started.runID)?.status.attention != nil }
    let attention = try #require(harness.engine.run(for: started.runID)?.status.attention)
    #expect(attention.reason == .injectionFailed)
    #expect(harness.world.notifications.contains { $0.0 == "Workflow · Ping" })
  }

  // MARK: - Delivery

  @Test
  func deliveryIsWrittenBeforeTheRunAdvances() async throws {
    let harness = try Self.makeHarness()
    let entry = try Self.entry(yaml: Self.yaml)
    let configuration = try Self.configuration(harness, entry: entry, selfInitiated: true)
    let started = try await harness.engine.start(configuration: configuration, entry: entry)
    let task = try #require(started.selfInitiated)
    #expect(harness.world.lines.isEmpty, "a self-initiated task is handed back, not typed")
    let token = try #require(harness.registry.activation(forPane: harness.paneID)?.token)
    #expect(task.completionCommand?.contains(token) == true)

    let wrong = await harness.engine.deliver(
      runID: started.runID, ordinal: 1, token: "nope", allowManual: false, force: false, body: "Done.", verdict: nil)
    guard case .rejected(let code, _) = wrong.outcome else {
      Issue.record("expected rejection")
      return
    }
    #expect(code == "TOKEN_INVALID")

    let right = await harness.engine.deliver(
      runID: started.runID, ordinal: 1, token: token, allowManual: false, force: false, body: "Done.", verdict: nil)
    #expect(right.outcome == .accepted)
    let record = try #require(right.delivery)
    #expect(FileManager.default.fileExists(atPath: record.path))
    #expect(FileManager.default.fileExists(atPath: record.latestPath))
    #expect(try String(contentsOfFile: record.path, encoding: .utf8) == "Done.")
    // The run went on to the notify step and completed.
    await Self.settle { harness.engine.session(for: started.runID)?.run.status.isTerminal == true }
    #expect(harness.engine.run(for: started.runID)?.status == .completed)
    #expect(harness.engine.activeRuns.isEmpty)
    #expect(harness.engine.finishedRuns.count == 1)
    #expect(harness.registry.activation(forPane: harness.paneID) == nil)
    #expect(harness.world.notifications.contains { $0.1.hasPrefix("Done ") })
    let index = try WorkflowRunIndex.load(worktreeRoot: harness.root)
    #expect(index.runs.map(\.id) == [started.runID])
  }

  // MARK: - Watchdog

  @Test
  func watchdogFiresAfterWorkingThenIdleForTheGrace() async throws {
    let harness = try Self.makeHarness()
    let entry = try Self.entry(yaml: Self.yaml)
    let configuration = try Self.configuration(harness, entry: entry, selfInitiated: true)
    let started = try await harness.engine.start(configuration: configuration, entry: entry)
    // Idle without ever working: nothing happens, however long it takes.
    harness.world.advance(60)
    try await Task.sleep(for: .milliseconds(40))
    #expect(harness.world.lines.isEmpty)

    harness.world.states[harness.paneID] = .working
    try await Task.sleep(for: .milliseconds(30))
    harness.world.states[harness.paneID] = .idle
    // The grace counts from the first idle observation, so let the poller
    // see idle before the clock jumps past the grace.
    try await Task.sleep(for: .milliseconds(30))
    harness.world.advance(11)
    await Self.settle { !harness.world.lines.isEmpty }
    let nudge = try #require(harness.world.lines.first)
    #expect(nudge.1.hasPrefix("[codans] When your work is complete"))
    #expect(harness.engine.run(for: started.runID)?.activations[1]?.nudged == true)

    // A second grace with no delivery becomes an attention.
    try await Task.sleep(for: .milliseconds(30))
    harness.world.advance(11)
    await Self.settle { harness.engine.run(for: started.runID)?.status.attention != nil }
    #expect(harness.engine.run(for: started.runID)?.status.attention?.reason == .noDeliveryAfterIdle)
  }

  // MARK: - Launch

  @Test
  func launchBindsThePaneAndRemembersTheProfile() async throws {
    let harness = try Self.makeHarness()
    let entry = try Self.entry(yaml: Self.launchYAML, id: "launch")
    let configuration = try Self.configuration(harness, entry: entry, selfInitiated: false)
    let started = try await harness.engine.start(configuration: configuration, entry: entry)
    await Self.settle { harness.engine.run(for: started.runID)?.phase == .waitingForDelivery(ordinal: 1) }
    let request = try #require(harness.world.launches.first)
    #expect(request.role == "reviewer")
    #expect(request.environment[CodansEnvironment.Key.workflowRun.rawValue] == started.runID.uuidString)
    #expect(request.environment[CodansEnvironment.Key.workflowToken.rawValue] != nil)
    #expect(harness.registry.runID(forPane: harness.world.launchPane) == started.runID)
    #expect(harness.registry.activation(forPane: harness.world.launchPane)?.ordinal == 1)
    #expect(harness.world.remembered.first?.role == "reviewer")
    #expect(harness.engine.run(for: started.runID)?.bindings["reviewer"]?.paneID == harness.world.launchPane)
  }

  @Test
  func cancelRevokesAndFinishes() async throws {
    let harness = try Self.makeHarness()
    let entry = try Self.entry(yaml: Self.yaml)
    let configuration = try Self.configuration(harness, entry: entry, selfInitiated: true)
    let started = try await harness.engine.start(configuration: configuration, entry: entry)
    #expect(harness.engine.cancel(runID: started.runID))
    await Self.settle { harness.engine.activeRuns.isEmpty }
    #expect(harness.engine.run(for: started.runID)?.status == .cancelled)
    #expect(harness.registry.activation(forPane: harness.paneID) == nil)
    #expect(harness.registry.runID(forPane: harness.paneID) == nil)
  }
}
