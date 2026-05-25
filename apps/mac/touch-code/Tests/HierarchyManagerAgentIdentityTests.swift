import Foundation
import Testing

@testable import TouchCodeCore
@testable import TouchCode

/// Coverage for `HierarchyManager.setPaneAgentKind` /
/// `setPaneAgentSessionID` — the catalog-write seam consumed by the
/// upcoming `AgentBinder` (`docs/exec-plans/active-agents-view.md` T3).
/// The contract:
///
///   1. A write reflects in the in-memory catalog snapshot immediately.
///   2. Repeat calls with the same value are a true no-op (no
///      `scheduleSave`), so identical re-classifications don't drive the
///      debounce.
///   3. Setting back to `nil` clears the field and schedules one save.
///
/// Tests instantiate `HierarchyManager` with a `RecordingCatalogStore`
/// that counts `scheduleSave` invocations — this is the only assertion
/// shape that catches the idempotence guard regressing.
@MainActor
struct HierarchyManagerAgentIdentityTests {
  // MARK: - agentKind

  @Test
  func setAgentKindReflectsInSnapshot() throws {
    let (manager, paneID, _) = Self.makeManager()
    manager.setPaneAgentKind(paneID, kind: .claudeCode)
    #expect(Self.readPane(manager, paneID: paneID)?.agentKind == .claudeCode)
  }

  @Test
  func setAgentKindRepeatWriteDoesNotScheduleSave() throws {
    let (manager, paneID, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setPaneAgentKind(paneID, kind: .claudeCode)
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setPaneAgentKind(paneID, kind: .claudeCode)
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setPaneAgentKind(paneID, kind: nil)
    #expect(store.scheduleSaveCallCount == baseline + 2)
  }

  @Test
  func clearAgentKindLeavesNil() throws {
    let (manager, paneID, store) = Self.makeManager(initialAgentKind: .claudeCode)
    let baseline = store.scheduleSaveCallCount

    manager.setPaneAgentKind(paneID, kind: nil)

    #expect(Self.readPane(manager, paneID: paneID)?.agentKind == nil)
    #expect(store.scheduleSaveCallCount == baseline + 1)
  }

  @Test
  func setAgentKindOnUnknownPaneIsSilentNoOp() throws {
    let (manager, _, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setPaneAgentKind(PaneID(), kind: .claudeCode)

    #expect(store.scheduleSaveCallCount == baseline)
  }

  // MARK: - agentSessionID

  @Test
  func setAgentSessionIDReflectsInSnapshot() throws {
    let (manager, paneID, _) = Self.makeManager()
    manager.setPaneAgentSessionID(paneID, sessionID: "session-abc")
    #expect(Self.readPane(manager, paneID: paneID)?.agentSessionID == "session-abc")
  }

  @Test
  func setAgentSessionIDRepeatWriteDoesNotScheduleSave() throws {
    let (manager, paneID, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setPaneAgentSessionID(paneID, sessionID: "session-abc")
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setPaneAgentSessionID(paneID, sessionID: "session-abc")
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setPaneAgentSessionID(paneID, sessionID: nil)
    #expect(store.scheduleSaveCallCount == baseline + 2)
  }

  @Test
  func clearAgentSessionIDLeavesNil() throws {
    let (manager, paneID, store) = Self.makeManager(initialSessionID: "session-abc")
    let baseline = store.scheduleSaveCallCount

    manager.setPaneAgentSessionID(paneID, sessionID: nil)

    #expect(Self.readPane(manager, paneID: paneID)?.agentSessionID == nil)
    #expect(store.scheduleSaveCallCount == baseline + 1)
  }

  @Test
  func setAgentSessionIDOnUnknownPaneIsSilentNoOp() throws {
    let (manager, _, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setPaneAgentSessionID(PaneID(), sessionID: "session-abc")

    #expect(store.scheduleSaveCallCount == baseline)
  }

  // MARK: - Helpers

  /// Constructs a `HierarchyManager` over a single-Project /
  /// single-Worktree / single-Tab / single-Pane catalog backed by a
  /// recording store so tests can assert on `scheduleSave` cardinality.
  private static func makeManager(
    initialAgentKind: AgentKind? = nil,
    initialSessionID: String? = nil
  ) -> (HierarchyManager, PaneID, RecordingCatalogStore) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("touch-code-agent-id-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let pane = Pane(
      workingDirectory: "/tmp",
      agentKind: initialAgentKind,
      agentSessionID: initialSessionID
    )
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(
      name: "main", path: "/repo", tabs: [tab], selectedTabID: tab.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let store = RecordingCatalogStore(fileURL: url)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: runtime)
    return (manager, pane.id, store)
  }

  private static func readPane(
    _ manager: HierarchyManager,
    paneID: PaneID
  ) -> Pane? {
    for project in manager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          if let pane = tab.panes.first(where: { $0.id == paneID }) {
            return pane
          }
        }
      }
    }
    return nil
  }
}

/// Test-only `CatalogStore` subclass that records how many times
/// `scheduleSave` was called. Used by `HierarchyManagerAgentIdentityTests`
/// to assert the idempotence guard in `setPaneAgentKind` /
/// `setPaneAgentSessionID` actually skips persistence on no-op writes.
@MainActor
final class RecordingCatalogStore: CatalogStore {
  private(set) var scheduleSaveCallCount: Int = 0

  override func scheduleSave(_ catalog: Catalog) {
    scheduleSaveCallCount += 1
    super.scheduleSave(catalog)
  }
}
