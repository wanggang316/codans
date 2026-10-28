import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct AgentNotificationConsistencyTests {
  @Test
  func oscNineWaitingNotifiesInboxWithoutFlippingLiveState() async {
    let fixture = Fixture()
    let title = "Approve this action?"
    let body = "Yes / No"
    #expect(PaneAttentionInterpreter.classify(title: title, body: body) == .waitingForInput)

    let events: [TerminalEvent] = [
      .paneOutput(fixture.contentID, Data()),
      .paneInfoChanged(fixture.contentID, .desktopNotification(title: title, body: body)),
    ]

    fixture.registry.onAgentBound(fixture.contentID, kind: .codex, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    // The inbox records the attention event; the live agent state is purely
    // render-derived and stays idle until the rendered region shows activity.
    #expect(fixture.registry.entries[fixture.contentID]?.state == .idle)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .waitingForInput)
    #expect(fixture.store.entries.first?.source.contentID == fixture.contentID)
  }

  @Test
  func bellRangNotifiesInboxWithoutFlippingLiveState() async {
    let fixture = Fixture()
    let events: [TerminalEvent] = [
      .paneOutput(fixture.contentID, Data()),
      .paneInfoChanged(fixture.contentID, .bellRang),
    ]

    fixture.registry.onAgentBound(fixture.contentID, kind: .codex, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    // Same decoupling for the bell: inbox-worthy, but not a live signal.
    #expect(fixture.registry.entries[fixture.contentID]?.state == .idle)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .waitingForInput)
    #expect(fixture.store.entries.first?.source.contentID == fixture.contentID)
  }

  @Test
  func oscNineTaskFinishedIsConsistent() async {
    let fixture = Fixture()
    let title = "Build complete"
    let body = "Exited 0"
    #expect(PaneAttentionInterpreter.classify(title: title, body: body) == .taskFinished)

    let events: [TerminalEvent] = [
      .paneOutput(fixture.contentID, Data()),
      .paneInfoChanged(fixture.contentID, .desktopNotification(title: title, body: body)),
    ]

    fixture.registry.onAgentBound(fixture.contentID, kind: .codex, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    #expect(fixture.registry.entries[fixture.contentID]?.state == .idle)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .taskFinished)
    #expect(fixture.store.entries.first?.source.contentID == fixture.contentID)
  }

  @Test
  func viewportLifecycleAndPaneIdleAreConsistent() async {
    let fixture = Fixture()
    fixture.registry.onAgentBound(fixture.contentID, kind: .codex, sessionID: nil)
    fixture.registry.onPaneKeyboardActivity(fixture.contentID)

    let working = TerminalEvent.paneViewportChanged(fixture.contentID, text: "• Working (10s)")
    fixture.registry.onTerminalEvent(working)
    await fixture.detector.handle(working)
    #expect(fixture.registry.entries[fixture.contentID]?.state == .working)

    let output = TerminalEvent.paneOutput(fixture.contentID, Data())
    fixture.registry.onTerminalEvent(output)
    await fixture.detector.handle(output)

    // The working→idle hold applies to every kind, so step the badge clock
    // past the window before the completion prompt so it settles rather than
    // debouncing back to working.
    fixture.nowBox.setValue(
      fixture.nowBox.value.addingTimeInterval(PaneAttentionInterpreter.agentWorkingHold + 0.5)
    )
    let idleViewport = TerminalEvent.paneViewportChanged(fixture.contentID, text: "codex> ")
    fixture.registry.onTerminalEvent(idleViewport)
    await fixture.detector.handle(idleViewport)
    #expect(fixture.registry.entries[fixture.contentID]?.state == .done)

    let idle = TerminalEvent.paneIdle(
      fixture.contentID,
      duration: PaneAttentionInterpreter.idleThreshold
    )
    fixture.registry.onTerminalEvent(idle)
    await fixture.detector.handle(idle)

    #expect(fixture.registry.entries[fixture.contentID]?.state == .done)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .taskFinished)
    #expect(fixture.store.entries.first?.source.contentID == fixture.contentID)
  }

  @Test
  func paneExitedTeardownIsConsistent() async {
    let fixture = Fixture()
    fixture.registry.onAgentBound(fixture.contentID, kind: .codex, sessionID: nil)
    #expect(fixture.registry.entries[fixture.contentID] != nil)

    let exit = TerminalEvent.paneExited(fixture.contentID, code: 0, signal: nil)
    fixture.registry.onTerminalEvent(exit)
    await fixture.detector.handle(exit)

    #expect(fixture.registry.entries[fixture.contentID] == nil)
    #expect(fixture.store.entries.isEmpty)
  }

  @MainActor
  final class Fixture {
    let contentID = ContentID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let registry: AgentStateStore
    let store: NotificationStore
    let coordinator: NotificationCoordinator
    let detector: NotificationDetector
    /// Injected badge clock so tests can step past `agentWorkingHold`.
    let nowBox = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))

    init() {
      let nowBox = self.nowBox
      self.registry = AgentStateStore(focusedPane: { nil }, now: { nowBox.value })

      let storeURL = FileManager.default.temporaryDirectory.appending(
        component: "notif-consistency-\(UUID().uuidString).json"
      )
      self.store = NotificationStore(fileURL: storeURL)

      let notifier = MockOSNotifier()
      let reader = FakeNotificationSettingsReader()
      var hierarchyClient = HierarchyClient.testValue
      hierarchyClient.promoteWorktree = { _, _, _ in }
      self.coordinator = NotificationCoordinator(
        inbox: store,
        osNotifier: notifier,
        settingsReader: reader,
        catalog: hierarchyClient,
        now: { Date() }
      )

      let catalog = Self.makeCatalog(
        projectID: projectID,
        worktreeID: worktreeID,
        tabID: tabID,
        contentID: contentID
      )
      self.detector = NotificationDetector(
        store: store,
        coordinator: coordinator,
        tracker: PaneKeyboardActivityTracker(),
        settingsReader: reader,
        catalogSnapshot: { catalog },
        isAppFrontmost: { false },
        onProjectActivity: nil
      )
    }

    private static func makeCatalog(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      tabID: TabID,
      contentID: ContentID
    ) -> Catalog {
      let tab = Tab(id: tabID, content: .terminal(id: contentID, workingDirectory: "/tmp"))
      let pane = Pane(tabs: [tab])
      let worktree = Worktree(
        id: worktreeID, name: "main", path: "/tmp",
        splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id)
      let project = Project(
        id: projectID,
        name: "Fixture",
        rootPath: "/tmp",
        worktrees: [worktree]
      )
      return Catalog(projects: [project])
    }
  }
}
