import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Coverage for `HierarchyManager.setAgentKind` / `setAgentSessionID` —
/// the catalog-write seam consumed by `AgentBinder`.
/// The contract:
///
///   1. A write reflects in the in-memory catalog snapshot immediately.
///   2. Repeat calls with the same value are a true no-op (no
///      `scheduleSave`), so identical re-classifications don't drive the
///      debounce.
///   3. Setting back to `nil` clears the field and schedules one save.
///   4. Bindings in the loaded catalog are dropped at launch: the agent
///      process they describe died with the previous session.
///
/// Tests instantiate `HierarchyManager` with a `RecordingCatalogStore`
/// that counts `scheduleSave` invocations — this is the only assertion
/// shape that catches the idempotence guard regressing.
@MainActor
struct HierarchyManagerAgentIdentityTests {
  // MARK: - agentKind

  @Test
  func setAgentKindReflectsInSnapshot() throws {
    let (manager, contentID, _) = Self.makeManager()
    manager.setAgentKind(contentID, kind: .claudeCode)
    #expect(Self.readContent(manager, contentID: contentID)?.agentKind == .claudeCode)
  }

  @Test
  func setAgentKindRepeatWriteDoesNotScheduleSave() throws {
    let (manager, contentID, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setAgentKind(contentID, kind: .claudeCode)
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setAgentKind(contentID, kind: .claudeCode)
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setAgentKind(contentID, kind: nil)
    #expect(store.scheduleSaveCallCount == baseline + 2)
  }

  @Test
  func clearAgentKindLeavesNil() throws {
    let (manager, contentID, store) = Self.makeManager()
    manager.setAgentKind(contentID, kind: .claudeCode)
    let baseline = store.scheduleSaveCallCount

    manager.setAgentKind(contentID, kind: nil)

    #expect(Self.readContent(manager, contentID: contentID)?.agentKind == nil)
    #expect(store.scheduleSaveCallCount == baseline + 1)
  }

  @Test
  func setAgentKindOnUnknownContentIsSilentNoOp() throws {
    let (manager, _, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setAgentKind(ContentID(), kind: .claudeCode)

    #expect(store.scheduleSaveCallCount == baseline)
  }

  // MARK: - agentSessionID

  @Test
  func setAgentSessionIDReflectsInSnapshot() throws {
    let (manager, contentID, _) = Self.makeManager()
    manager.setAgentSessionID(contentID, sessionID: "session-abc")
    #expect(Self.readContent(manager, contentID: contentID)?.agentSessionID == "session-abc")
  }

  @Test
  func setAgentSessionIDRepeatWriteDoesNotScheduleSave() throws {
    let (manager, contentID, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setAgentSessionID(contentID, sessionID: "session-abc")
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setAgentSessionID(contentID, sessionID: "session-abc")
    #expect(store.scheduleSaveCallCount == baseline + 1)

    manager.setAgentSessionID(contentID, sessionID: nil)
    #expect(store.scheduleSaveCallCount == baseline + 2)
  }

  @Test
  func clearAgentSessionIDLeavesNil() throws {
    let (manager, contentID, store) = Self.makeManager()
    manager.setAgentSessionID(contentID, sessionID: "session-abc")
    let baseline = store.scheduleSaveCallCount

    manager.setAgentSessionID(contentID, sessionID: nil)

    #expect(Self.readContent(manager, contentID: contentID)?.agentSessionID == nil)
    #expect(store.scheduleSaveCallCount == baseline + 1)
  }

  @Test
  func setAgentSessionIDOnUnknownContentIsSilentNoOp() throws {
    let (manager, _, store) = Self.makeManager()
    let baseline = store.scheduleSaveCallCount

    manager.setAgentSessionID(ContentID(), sessionID: "session-abc")

    #expect(store.scheduleSaveCallCount == baseline)
  }

  // MARK: - Launch

  @Test
  func loadedBindingsAreClearedAndSaved() throws {
    let (manager, contentID, store) = Self.makeManager(
      initialAgentKind: .claudeCode,
      initialSessionID: "session-abc"
    )

    let pane = Self.readContent(manager, contentID: contentID)
    #expect(pane?.agentKind == nil)
    #expect(pane?.agentSessionID == nil)
    #expect(store.scheduleSaveCallCount == 1)
  }

  // MARK: - Helpers

  /// Constructs a `HierarchyManager` over a single-Project /
  /// single-Worktree / single-Pane / single-Tab catalog backed by a
  /// recording store so tests can assert on `scheduleSave` cardinality.
  private static func makeManager(
    initialAgentKind: AgentKind? = nil,
    initialSessionID: String? = nil
  ) -> (HierarchyManager, ContentID, RecordingCatalogStore) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("codans-agent-id-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("catalog.json")

    let tab = Tab(
      content: .terminal(
        workingDirectory: "/tmp", agentKind: initialAgentKind, agentSessionID: initialSessionID))
    let pane = Pane(tabs: [tab])
    let worktree = Worktree(
      name: "main", path: "/repo", splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id
    )
    let project = Project(
      name: "p", rootPath: "/repo", gitRoot: "/repo",
      worktrees: [worktree], selectedWorktreeID: worktree.id
    )
    let catalog = Catalog(projects: [project])

    let store = RecordingCatalogStore(fileURL: url)
    let runtime = FakeHierarchyRuntime()
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: runtime)
    return (manager, tab.contentID, store)
  }

  private static func readContent(
    _ manager: HierarchyManager,
    contentID: ContentID
  ) -> TerminalContentState? {
    manager.catalog.content(contentID)?.terminal
  }
}

/// Test-only `CatalogStore` subclass that records how many times
/// `scheduleSave` was called. Used by `HierarchyManagerAgentIdentityTests`
/// to assert the idempotence guard in `setAgentKind` / `setAgentSessionID`
/// actually skips persistence on no-op writes.
@MainActor
final class RecordingCatalogStore: CatalogStore {
  private(set) var scheduleSaveCallCount: Int = 0

  override func scheduleSave(_ catalog: Catalog) {
    scheduleSaveCallCount += 1
    super.scheduleSave(catalog)
  }
}
