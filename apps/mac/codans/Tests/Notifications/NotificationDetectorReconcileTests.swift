import CodansCore
import Foundation
import Testing

@testable import Codans

/// Coverage for `NotificationDetector.reconcileMembership`.
///
/// The detector's per-pane caches are otherwise cleared only by the
/// interpreter's teardown branch, which runs on `.paneExited` and its two
/// siblings. Archive and project removal tear down through `suspendSurface`,
/// which deliberately emits none of those, so the caches outlived their panes.
@MainActor
struct NotificationDetectorReconcileTests {
  @Test
  func reconcileDropsPanesAbsentFromTheCatalog() async {
    let f = Fixture()

    await f.detector.handle(.paneOutput(f.contentID, Data("build ok\n".utf8)))
    await f.detector.handle(.paneIdle(f.contentID, duration: 60))
    #expect(f.detector.trackedContentsForTesting == [f.contentID])
    #expect(f.store.entries.count == 1)

    // Archive's shape: the pane drops out of `visibleContentIDs()` while the
    // catalog still holds it, and no `.paneExited` is ever emitted.
    f.detector.reconcileMembership(liveContentIDs: [])

    #expect(f.detector.trackedContentsForTesting.isEmpty)
  }

  @Test
  func reconcileKeepsPanesThatAreStillLive() async {
    let f = Fixture()

    await f.detector.handle(.paneOutput(f.contentID, Data("build ok\n".utf8)))
    f.detector.reconcileMembership(liveContentIDs: [f.contentID])

    #expect(f.detector.trackedContentsForTesting == [f.contentID])
    await f.detector.handle(.paneIdle(f.contentID, duration: 60))
    #expect(f.store.entries.count == 1)
  }

  @MainActor
  private struct Fixture {
    let store: NotificationStore
    let detector: NotificationDetector
    let contentID: ContentID

    init() {
      let contentID = ContentID()
      let tabID = TabID()
      let worktreeID = WorktreeID()
      let projectID = ProjectID()
      self.contentID = contentID

      let storeURL = FileManager.default.temporaryDirectory.appending(
        component: "notif-detector-reconcile-\(UUID().uuidString).json"
      )
      let store = NotificationStore(fileURL: storeURL)
      self.store = store

      let reader = FakeNotificationSettingsReader()
      var hierarchyClient = HierarchyClient.testValue
      hierarchyClient.promoteWorktree = { _, _, _ in }
      let coordinator = NotificationCoordinator(
        inbox: store,
        osNotifier: MockOSNotifier(),
        settingsReader: reader,
        catalog: hierarchyClient,
        now: { Date() }
      )

      let tab = Tab(id: tabID, content: .terminal(id: contentID, workingDirectory: "/tmp"))
      let pane = Pane(tabs: [tab])
      let worktree = Worktree(
        id: worktreeID, name: "main", path: "/tmp",
        splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id)
      let project = Project(id: projectID, name: "p", rootPath: "/tmp", worktrees: [worktree])
      let catalog = Catalog(projects: [project])

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
  }
}
