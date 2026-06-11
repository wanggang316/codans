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
      .paneOutput(fixture.paneID, Data()),
      .paneInfoChanged(fixture.paneID, .desktopNotification(title: title, body: body)),
    ]

    fixture.registry.onAgentBound(fixture.paneID, kind: .codex, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    // The inbox records the attention event; the live agent state is purely
    // render-derived and stays idle until the rendered region shows activity.
    #expect(fixture.registry.entries[fixture.paneID]?.state == .idle)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .waitingForInput)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  @Test
  func bellRangNotifiesInboxWithoutFlippingLiveState() async {
    let fixture = Fixture()
    let events: [TerminalEvent] = [
      .paneOutput(fixture.paneID, Data()),
      .paneInfoChanged(fixture.paneID, .bellRang),
    ]

    fixture.registry.onAgentBound(fixture.paneID, kind: .codex, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    // Same decoupling for the bell: inbox-worthy, but not a live signal.
    #expect(fixture.registry.entries[fixture.paneID]?.state == .idle)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .waitingForInput)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  @Test
  func oscNineTaskFinishedIsConsistent() async {
    let fixture = Fixture()
    let title = "Build complete"
    let body = "Exited 0"
    #expect(PaneAttentionInterpreter.classify(title: title, body: body) == .taskFinished)

    let events: [TerminalEvent] = [
      .paneOutput(fixture.paneID, Data()),
      .paneInfoChanged(fixture.paneID, .desktopNotification(title: title, body: body)),
    ]

    fixture.registry.onAgentBound(fixture.paneID, kind: .codex, sessionID: nil)
    for event in events {
      fixture.registry.onTerminalEvent(event)
      await fixture.detector.handle(event)
    }

    #expect(fixture.registry.entries[fixture.paneID]?.state == .idle)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .taskFinished)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  @Test
  func viewportLifecycleAndPaneIdleAreConsistent() async {
    let fixture = Fixture()
    fixture.registry.onAgentBound(fixture.paneID, kind: .codex, sessionID: nil)
    fixture.registry.onPaneKeyboardActivity(fixture.paneID)

    let working = TerminalEvent.paneViewportChanged(fixture.paneID, text: "• Working (10s)")
    fixture.registry.onTerminalEvent(working)
    await fixture.detector.handle(working)
    #expect(fixture.registry.entries[fixture.paneID]?.state == .working)

    let output = TerminalEvent.paneOutput(fixture.paneID, Data())
    fixture.registry.onTerminalEvent(output)
    await fixture.detector.handle(output)

    let idleViewport = TerminalEvent.paneViewportChanged(fixture.paneID, text: "codex> ")
    fixture.registry.onTerminalEvent(idleViewport)
    await fixture.detector.handle(idleViewport)
    #expect(fixture.registry.entries[fixture.paneID]?.state == .finished)

    let idle = TerminalEvent.paneIdle(
      fixture.paneID,
      duration: PaneAttentionInterpreter.idleThreshold
    )
    fixture.registry.onTerminalEvent(idle)
    await fixture.detector.handle(idle)

    #expect(fixture.registry.entries[fixture.paneID]?.state == .finished)
    #expect(fixture.store.entries.count == 1)
    #expect(fixture.store.entries.first?.kind == .taskFinished)
    #expect(fixture.store.entries.first?.source.paneID == fixture.paneID)
  }

  @Test
  func paneExitedTeardownIsConsistent() async {
    let fixture = Fixture()
    fixture.registry.onAgentBound(fixture.paneID, kind: .codex, sessionID: nil)
    #expect(fixture.registry.entries[fixture.paneID] != nil)

    let exit = TerminalEvent.paneExited(fixture.paneID, code: 0, signal: nil)
    fixture.registry.onTerminalEvent(exit)
    await fixture.detector.handle(exit)

    #expect(fixture.registry.entries[fixture.paneID] == nil)
    #expect(fixture.store.entries.isEmpty)
  }

  @MainActor
  final class Fixture {
    let paneID = PaneID()
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let tabID = TabID()

    let registry: AgentStateStore
    let store: NotificationStore
    let coordinator: NotificationCoordinator
    let detector: NotificationDetector

    init() {
      self.registry = AgentStateStore(focusedPane: { nil })

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
        paneID: paneID
      )
      self.detector = NotificationDetector(
        store: store,
        coordinator: coordinator,
        tracker: PaneKeyboardActivityTracker(),
        settingsReader: reader,
        catalogSnapshot: { catalog },
        lastFocusedPane: { _ in nil },
        isAppFrontmost: { false },
        onProjectActivity: nil
      )
    }

    private static func makeCatalog(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      tabID: TabID,
      paneID: PaneID
    ) -> Catalog {
      let pane = Pane(id: paneID, workingDirectory: "/tmp")
      let tab = Tab(id: tabID, panes: [pane])
      let worktree = Worktree(id: worktreeID, name: "main", path: "/tmp", tabs: [tab])
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
