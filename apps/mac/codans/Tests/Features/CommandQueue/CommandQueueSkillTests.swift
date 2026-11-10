import AppKit
import CodansCore
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import Codans

/// Agent Skill completion in the Command Queue composer: the reducer follows
/// the agent that runs in the target pane and its directory, and the real
/// composer view routes Return, Tab, and Escape through the shared
/// completion modifier.
@MainActor
@Suite(.serialized)
struct CommandQueueSkillTests {
  private nonisolated static let skills = ["code-review", "tdd"].map {
    AgentSkillEntry(name: $0, summary: nil, source: .user, url: URL(fileURLWithPath: "/tmp/skills/\($0)"))
  }

  private static func catalog(
    paneID: PaneID, agent: AgentKind?, cwd: String = "/tmp/queue/repo/sub", remote: Bool = false
  ) -> Catalog {
    let pane = Pane(id: paneID, workingDirectory: cwd, agentKind: agent)
    let worktree = Worktree(name: "repo", path: "/tmp/queue/repo", tabs: [Tab(panes: [pane])])
    let project = Project(
      name: "repo", rootPath: "/tmp/queue/repo",
      remoteHost: remote ? RemoteHost(alias: "devbox") : nil, worktrees: [worktree])
    return Catalog(projects: [project])
  }

  /// A Claude Code process with its own home and a launch flag, run in
  /// the pane's subfolder.
  private nonisolated static func claude(
    pid: Int32 = 41, arguments: [String] = ["--settings", "/srv/s.json"],
    cwd: String? = "/tmp/queue/repo/sub/agent"
  ) -> RunningAgent {
    RunningAgent(
      pid: pid,
      launch: SkillLaunch(
        kind: .claudeCode, arguments: arguments,
        environment: ["HOME": "/srv/agent-home", "PATH": "/usr/bin"]),
      workingDirectory: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
  }

  /// What a skill scan was asked for: the launch and the start directory.
  private struct Load: Equatable, Sendable {
    var launch: SkillLaunch
    var start: String?
    var newWorktree: NewWorktreeSource?
  }

  private static func makeStore(
    catalog: Catalog, paneID: PaneID, loads: LockIsolated<[Load]>,
    running: LockIsolated<RunningAgent?> = LockIsolated(claude())
  ) -> TestStoreOf<CommandQueueFeature> {
    TestStore(initialState: CommandQueueFeature.State(paneID: paneID)) {
      CommandQueueFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0.hierarchyClient.paneChanges = { paneID in
        AsyncStream { continuation in
          continuation.yield(catalog.pane(paneID))
          continuation.finish()
        }
      }
      $0.terminalClient.runningAgent = { _, _ in running.value }
      $0[AgentSkillClient.self].load = { launch, start, newWorktree in
        loads.withValue {
          $0.append(Load(launch: launch, start: start?.path(percentEncoded: false), newWorktree: newWorktree))
        }
        return skills
      }
    }
  }

  private static func scope(_ agent: RunningAgent) -> CommandQueueFeature.SkillScope {
    CommandQueueFeature.SkillScope(
      pid: agent.pid, launch: agent.launch!, projectStart: agent.workingDirectory)
  }

  // MARK: - Reducer

  @Test
  func runningAgentSkillsLoadWithItsLaunchAndDirectory() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .claudeCode)
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads)
    await store.send(.onAppear)
    await store.receive(.paneChanged(catalog.pane(paneID))) {
      $0.skillLocation = .claudeCode
      $0.skillsUnavailableReason = nil
      $0.skillsScope = Self.scope(Self.claude())
    }
    await store.receive(.skillsLoaded(Self.skills, for: Self.scope(Self.claude()))) { $0.skills = Self.skills }
    #expect(loads.value == [Load(launch: Self.claude().launch!, start: "/tmp/queue/repo/sub/agent/")])
    // The agent's own home and flags, not the user's defaults.
    #expect(loads.value.first?.launch.profile.envVars == ["HOME": "/srv/agent-home"])
    #expect(loads.value.first?.launch.arguments == ["--settings", "/srv/s.json"])

    await store.send(.draftChanged("fix")) { $0.draft = "fix" }
    await store.send(.skillsButtonTapped(selection: 3..<3)) { $0.draft = "fix /" }
  }

  @Test
  func unreadableAgentDirectoryFallsBackToThePaneDirectory() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .claudeCode)
    let store = Self.makeStore(
      catalog: catalog, paneID: paneID, loads: loads, running: LockIsolated(Self.claude(cwd: nil)))
    store.exhaustivity = .off
    await store.send(.paneChanged(catalog.pane(paneID)))
    await store.receive(\.skillsLoaded)
    #expect(loads.value.map(\.start) == ["/tmp/queue/repo/sub/"])
  }

  @Test
  func codexPaneUsesItsOwnCallPrefix() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .codex)
    let codex = RunningAgent(
      pid: 7, launch: SkillLaunch(kind: .codex, arguments: [], environment: ["PATH": "/usr/bin"]),
      workingDirectory: nil)
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads, running: LockIsolated(codex))
    store.exhaustivity = .off
    await store.send(.paneChanged(catalog.pane(paneID)))
    await store.receive(\.skillsLoaded)
    #expect(store.state.skillLocation == .codex)
    await store.send(.skillsButtonTapped(selection: nil)) { $0.draft = "$" }
  }

  @Test
  func paneWithoutAnAgentOffersNoSkills() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: nil)
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads)
    await store.send(.paneChanged(catalog.pane(paneID)))
    #expect(store.state.skillLocation == .none)
    #expect(store.state.skillsUnavailableReason == CommandQueueFeature.State.noAgentReason)
    await store.send(.skillsButtonTapped(selection: nil))
    #expect(loads.value.isEmpty)
  }

  @Test
  func unsupportedAgentOffersNoSkills() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .gemini)
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads)
    await store.send(.paneChanged(catalog.pane(paneID))) {
      $0.skillsUnavailableReason =
        "Skill suggestions are not available for \(AgentKind.gemini.displayName)"
    }
    #expect(store.state.skillLocation == .none)
    #expect(loads.value.isEmpty)
  }

  @Test
  func remoteProjectOffersNoSkills() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .claudeCode, remote: true)
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads)
    await store.send(.paneChanged(catalog.pane(paneID))) {
      $0.skillsUnavailableReason = "Skill suggestions are not available for remote projects"
    }
    #expect(store.state.skillLocation == .none)
    #expect(loads.value.isEmpty)
  }

  /// An agent process codans cannot find, or whose environment the kernel
  /// does not give, may run with another home or other flags, so it gets
  /// no list (ADR 0010).
  @Test
  func unreadableLaunchOffersNoSkills() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .claudeCode)
    let running = LockIsolated<RunningAgent?>(nil)
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads, running: running)
    await store.send(.paneChanged(catalog.pane(paneID))) {
      $0.skillsUnavailableReason = CommandQueueFeature.State.unreadableLaunchReason
    }
    running.setValue(RunningAgent(pid: 9, launch: nil, workingDirectory: nil))
    await store.send(.paneChanged(catalog.pane(paneID)))
    #expect(store.state.skillLocation == .none)
    #expect(loads.value.isEmpty)
  }

  /// The pane's agent changes while the panel is open: the old skills go
  /// at once, the new agent's load, and a late result for the old agent is
  /// dropped.
  @Test
  func agentChangeWhileOpenReloadsAndDropsTheOldResult() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let catalog = Self.catalog(paneID: paneID, agent: .claudeCode)
    let running = LockIsolated<RunningAgent?>(Self.claude())
    let store = Self.makeStore(catalog: catalog, paneID: paneID, loads: loads, running: running)
    let pane = catalog.pane(paneID)
    let first = Self.scope(Self.claude())
    await store.send(.paneChanged(pane)) {
      $0.skillLocation = .claudeCode
      $0.skillsUnavailableReason = nil
      $0.skillsScope = first
    }
    await store.receive(.skillsLoaded(Self.skills, for: first)) { $0.skills = Self.skills }

    // The same agent again (another pane field changed): nothing reloads.
    await store.send(.paneChanged(pane))

    // A new agent process with other flags.
    let restarted = Self.claude(pid: 42, arguments: [])
    running.setValue(restarted)
    await store.send(.paneChanged(pane)) {
      $0.skills = []
      $0.skillsScope = Self.scope(restarted)
    }
    await store.receive(.skillsLoaded(Self.skills, for: Self.scope(restarted))) { $0.skills = Self.skills }
    // A late result for the old agent changes nothing.
    await store.send(.skillsLoaded([Self.skills[0]], for: first))

    // The agent exits.
    var exited = pane
    exited?.agentKind = nil
    await store.send(.paneChanged(exited)) {
      $0.skillLocation = .none
      $0.skills = []
      $0.skillsScope = nil
      $0.skillsUnavailableReason = CommandQueueFeature.State.noAgentReason
    }
    #expect(loads.value.count == 2)
  }

  // MARK: - Composer keys

  @MainActor
  final class Recorder {
    var queue: [QueuedCommand] = []
    var dismissed = 0
  }

  private struct Composer {
    let window: NSWindow
    let store: StoreOf<CommandQueueFeature>
    let recorder: Recorder
    let textView: NSTextView
  }

  private static func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }

  private static func showComposer(agent: AgentKind? = .claudeCode) throws -> Composer {
    let paneID = PaneID()
    let recorder = Recorder()
    let catalog = catalog(paneID: paneID, agent: agent)
    let store = Store(initialState: CommandQueueFeature.State(paneID: paneID)) {
      CommandQueueFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[HierarchyClient.self].commandQueue = { _ in recorder.queue }
      $0[HierarchyClient.self].setCommandQueue = { _, queue in recorder.queue = queue }
      $0.date = .constant(Date(timeIntervalSinceReferenceDate: 1_000_000))
      $0.hierarchyClient.paneChanges = { paneID in
        AsyncStream { continuation in
          continuation.yield(catalog.pane(paneID))
          continuation.finish()
        }
      }
      $0.terminalClient.runningAgent = { _, _ in claude() }
      $0[AgentSkillClient.self].load = { _, _, _ in skills }
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 320), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: CommandQueueView(store: store, onDismiss: { recorder.dismissed += 1 }))
    window.makeKeyAndOrderFront(nil)
    settle()
    func find(_ view: NSView) -> NSTextView? {
      if let textView = view as? NSTextView { return textView }
      return view.subviews.lazy.compactMap(find).first
    }
    let textView = try #require(window.contentView.flatMap(find))
    window.makeFirstResponder(textView)
    settle()
    return Composer(window: window, store: store, recorder: recorder, textView: textView)
  }

  private static func type(_ characters: String, in composer: Composer) {
    composer.textView.insertText(characters, replacementRange: composer.textView.selectedRange())
    settle()
  }

  private static func press(
    _ key: (UInt16, String), modifiers: NSEvent.ModifierFlags = [], in composer: Composer
  ) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: composer.window.windowNumber, context: nil, characters: key.1,
      charactersIgnoringModifiers: key.1, isARepeat: false, keyCode: key.0)
    if let event { composer.window.sendEvent(event) }
    settle()
  }

  private static let returnKey: (UInt16, String) = (36, "\r")
  private static let tabKey: (UInt16, String) = (48, "\t")
  private static let escapeKey: (UInt16, String) = (53, "\u{1b}")

  @Test
  func closedListReturnQueuesTheDraftAndEscapeClosesTheSheet() throws {
    let composer = try Self.showComposer()
    defer { composer.window.close() }
    Self.type("make test", in: composer)
    Self.press(Self.returnKey, in: composer)
    #expect(composer.recorder.queue.map(\.text) == ["make test"])
    #expect(composer.store.draft.isEmpty)
    Self.press(Self.escapeKey, in: composer)
    #expect(composer.recorder.dismissed == 1)
  }

  @Test
  func returnOnAnEmptyDraftDoesNothingAndShiftReturnBreaksALine() throws {
    let composer = try Self.showComposer()
    defer { composer.window.close() }
    Self.press(Self.returnKey, in: composer)
    #expect(composer.recorder.queue.isEmpty)
    #expect(composer.store.draft.isEmpty)
    Self.type("fix", in: composer)
    Self.press(Self.returnKey, modifiers: .shift, in: composer)
    #expect(composer.store.draft == "fix\n")
    #expect(composer.recorder.queue.isEmpty)
  }

  @Test
  func openListTakesReturnTabAndEscape() async throws {
    let composer = try Self.showComposer()
    defer { composer.window.close() }
    // The skill scan answers through an effect, which runs only once the
    // test gives the main actor back.
    for _ in 0..<50 where composer.store.skills.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    Self.settle()
    #expect(composer.store.skillLocation == .claudeCode)
    #expect(composer.store.skills == Self.skills)
    Self.type("run /td", in: composer)
    #expect(composer.store.draft == "run /td")
    Self.press(Self.returnKey, in: composer)
    #expect(composer.store.draft == "run /tdd ")
    #expect(composer.recorder.queue.isEmpty)

    Self.type("/co", in: composer)
    Self.press(Self.tabKey, in: composer)
    #expect(composer.store.draft == "run /tdd /code-review ")

    Self.type("/", in: composer)
    Self.press(Self.escapeKey, in: composer)
    #expect(composer.recorder.dismissed == 0)
    Self.press(Self.escapeKey, in: composer)
    #expect(composer.recorder.dismissed == 1)
  }

  @Test
  func paneWithoutAnAgentKeepsTheSlashAsText() throws {
    let composer = try Self.showComposer(agent: nil)
    defer { composer.window.close() }
    Self.type("/td", in: composer)
    Self.press(Self.returnKey, in: composer)
    #expect(composer.recorder.queue.map(\.text) == ["/td"])
  }
}
