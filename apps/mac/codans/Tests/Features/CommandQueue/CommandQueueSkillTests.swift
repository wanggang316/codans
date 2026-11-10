import AppKit
import CodansCore
import ComposableArchitecture
import Foundation
import SwiftUI
import Testing

@testable import Codans

/// Agent Skill completion in the Command Queue composer: the reducer reads
/// the agent and the working directory of the target pane, and the real
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

  /// What a skill scan was asked for: the agent and the start directory.
  private struct Load: Equatable, Sendable {
    var kind: AgentKind
    var usesDefaults: Bool
    var start: String?
    var newWorktree: NewWorktreeSource?
  }

  private static func makeStore(
    catalog: Catalog, paneID: PaneID, loads: LockIsolated<[Load]>
  ) -> TestStoreOf<CommandQueueFeature> {
    TestStore(initialState: CommandQueueFeature.State(paneID: paneID)) {
      CommandQueueFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { catalog }
      $0[AgentSkillClient.self].load = { profile, start, newWorktree in
        loads.withValue {
          $0.append(
            Load(
              kind: profile.kind, usesDefaults: profile == AgentProfile(id: profile.id, kind: profile.kind),
              start: start?.path(percentEncoded: false), newWorktree: newWorktree))
        }
        return skills
      }
    }
  }

  // MARK: - Reducer

  @Test
  func paneAgentSkillsLoadForItsWorkingDirectory() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let store = Self.makeStore(
      catalog: Self.catalog(paneID: paneID, agent: .claudeCode), paneID: paneID, loads: loads)
    await store.send(.onAppear) {
      $0.skillLocation = .claudeCode
      $0.skillsUnavailableReason = nil
    }
    await store.receive(.skillsLoaded(Self.skills)) { $0.skills = Self.skills }
    #expect(loads.value == [Load(kind: .claudeCode, usesDefaults: true, start: "/tmp/queue/repo/sub/")])

    await store.send(.draftChanged("fix")) { $0.draft = "fix" }
    await store.send(.skillsButtonTapped(selection: 3..<3)) { $0.draft = "fix /" }
  }

  @Test
  func codexPaneUsesItsOwnCallPrefix() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let store = Self.makeStore(
      catalog: Self.catalog(paneID: paneID, agent: .codex), paneID: paneID, loads: loads)
    await store.send(.onAppear) {
      $0.skillLocation = .codex
      $0.skillsUnavailableReason = nil
    }
    await store.receive(.skillsLoaded(Self.skills)) { $0.skills = Self.skills }
    await store.send(.skillsButtonTapped(selection: nil)) { $0.draft = "$" }
  }

  @Test
  func paneWithoutAnAgentOffersNoSkills() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let store = Self.makeStore(
      catalog: Self.catalog(paneID: paneID, agent: nil), paneID: paneID, loads: loads)
    await store.send(.onAppear)
    #expect(store.state.skillLocation == .none)
    #expect(store.state.skillsUnavailableReason == CommandQueueFeature.State.noAgentReason)
    await store.send(.skillsButtonTapped(selection: nil))
    #expect(loads.value.isEmpty)
  }

  @Test
  func unsupportedAgentOffersNoSkills() async {
    let paneID = PaneID()
    let loads = LockIsolated<[Load]>([])
    let store = Self.makeStore(
      catalog: Self.catalog(paneID: paneID, agent: .gemini), paneID: paneID, loads: loads)
    await store.send(.onAppear) {
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
    let store = Self.makeStore(
      catalog: Self.catalog(paneID: paneID, agent: .claudeCode, remote: true), paneID: paneID,
      loads: loads)
    await store.send(.onAppear) {
      $0.skillsUnavailableReason = "Skill suggestions are not available for remote projects"
    }
    #expect(store.state.skillLocation == .none)
    #expect(loads.value.isEmpty)
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
