import CodansCore
import Foundation
import Testing

@testable import Codans

/// Coverage for the detector's "the user is already looking at the source
/// pane" drop. A notification from the focused pane must produce no inbox
/// row and no banner.
@MainActor
struct NotificationDetectorFocusTests {
  @Test
  func dropsWhenTheUserHasObservedTheSource() async {
    // The catalog-level focus map knows nothing about the pane (it is
    // runtime-only and can lag behind AppKit), but the pane has keyboard
    // focus, or the user looked at it after its agent stopped.
    let f = Fixture(isPaneObserved: { _ in true }, lastFocusedPane: { _ in nil })

    await f.detector.handle(.paneInfoChanged(f.paneID, .desktopNotification(title: "Claude", body: "done")))

    #expect(f.store.entries.isEmpty)
    #expect(f.osNotifier.posts.isEmpty)
  }

  @Test
  func dropsWhenTheDisplayedSelectionFocusesTheSource() async {
    // No explicit `selectedProjectID`: the window shows the first project
    // that remembers a selected worktree, so its focused pane counts.
    let f = Fixture(isPaneObserved: { _ in false }, lastFocusedPane: nil, selectsProject: false)

    await f.detector.handle(.paneInfoChanged(f.paneID, .desktopNotification(title: "Claude", body: "done")))

    #expect(f.store.entries.isEmpty)
    #expect(f.osNotifier.posts.isEmpty)
  }

  @Test
  func postsWhenTheSourceIsNotFocused() async {
    let f = Fixture(isPaneObserved: { _ in false }, lastFocusedPane: { _ in nil })

    await f.detector.handle(.paneInfoChanged(f.paneID, .desktopNotification(title: "Claude", body: "done")))

    #expect(f.store.entries.count == 1)
    #expect(f.osNotifier.posts.count == 1)
  }

  @MainActor
  private struct Fixture {
    let store: NotificationStore
    let osNotifier: MockOSNotifier
    let detector: NotificationDetector
    let paneID: PaneID

    /// `lastFocusedPane == nil` means "the tab remembers the source pane".
    init(
      isPaneObserved: @escaping @MainActor (PaneID) -> Bool,
      lastFocusedPane: (@MainActor (TabID) -> PaneID?)?,
      selectsProject: Bool = true
    ) {
      let paneID = PaneID()
      let tabID = TabID()
      let worktreeID = WorktreeID()
      let projectID = ProjectID()
      self.paneID = paneID

      let storeURL = FileManager.default.temporaryDirectory.appending(
        component: "notif-detector-focus-\(UUID().uuidString).json"
      )
      let store = NotificationStore(fileURL: storeURL)
      self.store = store

      let reader = FakeNotificationSettingsReader()
      let osNotifier = MockOSNotifier()
      self.osNotifier = osNotifier
      var hierarchyClient = HierarchyClient.testValue
      hierarchyClient.promoteWorktree = { _, _, _ in }
      let coordinator = NotificationCoordinator(
        inbox: store,
        osNotifier: osNotifier,
        settingsReader: reader,
        catalog: hierarchyClient,
        now: { Date() }
      )

      let pane = Pane(id: paneID, workingDirectory: "/tmp")
      let tab = Tab(id: tabID, panes: [pane])
      let worktree = Worktree(
        id: worktreeID, name: "main", path: "/tmp", tabs: [tab], selectedTabID: tabID)
      let project = Project(
        id: projectID, name: "p", rootPath: "/tmp", worktrees: [worktree], selectedWorktreeID: worktreeID)
      let catalog = Catalog(projects: [project], selectedProjectID: selectsProject ? projectID : nil)

      self.detector = NotificationDetector(
        store: store,
        coordinator: coordinator,
        tracker: PaneKeyboardActivityTracker(),
        settingsReader: reader,
        catalogSnapshot: { catalog },
        lastFocusedPane: lastFocusedPane ?? { _ in paneID },
        isAppFrontmost: { true },
        isPaneObserved: isPaneObserved,
        onProjectActivity: nil
      )
    }
  }
}
