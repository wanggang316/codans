import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The sidebar creation flow holds a creation lease from the start of the
/// stream until the catalog write, and releases it on every exit path.
/// Without it, a reconcile that runs while `git worktree add` streams
/// appends the new path at the list tail.
@MainActor
struct HierarchySidebarCreationLeaseTests {
  private enum LeaseEvent: Equatable {
    case begin(WorktreeCreationLease)
    case end(WorktreeCreationLease)
  }

  private static func makePending(
    projectID: ProjectID, status: PendingWorktree.Status = .running
  ) -> PendingWorktree {
    PendingWorktree(
      id: PendingWorktreeID(),
      projectID: projectID,
      spec: CreateWorktreeSpec(
        repoRoot: URL(fileURLWithPath: "/repo"),
        baseDirectory: URL(fileURLWithPath: "/repo/.worktrees"),
        name: "feat-x",
        baseRef: "origin/main",
        fetchOrigin: false,
        copyIgnored: false,
        copyUntracked: false
      ),
      displayName: "feat/x",
      status: status,
      lastProgressLine: nil,
      startedAt: Date(timeIntervalSince1970: 0)
    )
  }

  private static func lease(for pending: PendingWorktree) -> WorktreeCreationLease {
    WorktreeCreationLease(projectID: pending.projectID, token: pending.id.raw)
  }

  private static func record(
    _ events: LockIsolated<[LeaseEvent]>, into deps: inout DependencyValues
  ) {
    deps.hierarchyClient.beginWorktreeCreation = { lease in
      events.withValue { $0.append(.begin(lease)) }
    }
    deps.hierarchyClient.endWorktreeCreation = { lease in
      events.withValue { $0.append(.end(lease)) }
    }
  }

  // MARK: - Race against a real manager

  @Test
  func reconcileDuringStreamDoesNotMoveTheNewRowToTheTail() async throws {
    let manager = HierarchyManager(
      catalog: Catalog(),
      store: CatalogStore(
        fileURL: FileManager.default.temporaryDirectory
          .appending(component: "codans-lease-\(UUID().uuidString).json")),
      runtime: FakeHierarchyRuntime()
    )
    let projectID = manager.addProject(name: "repo", rootPath: "/repo", gitRoot: "/repo")
    _ = try manager.createWorktree(in: projectID, name: "main", path: "/repo", branch: "main")
    let olderID = try manager.createWorktree(
      in: projectID, name: "older", path: "/repo/.worktrees/older", branch: "older")
    var releasedProjects: [ProjectID] = []
    manager.onCreationLeasesReleased = { releasedProjects.append($0) }

    let pending = Self.makePending(projectID: projectID)
    let id = pending.id
    let materialized = URL(fileURLWithPath: "/repo/.worktrees/feat-x")
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient = HierarchyClient.live(manager: manager)
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      // Never ends: the test drives the finish itself, after the race.
      $0.gitWorktreeClient.createWorktreeStream = { _ in AsyncThrowingStream { _ in } }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    #expect(manager.holdsCreationLease(projectID))

    // `git worktree add` has run; a reconcile pulse lands before the
    // catalog write.
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [
        (path: "/repo", branch: "main", head: nil),
        (path: "/repo/.worktrees/older", branch: "older", head: nil),
        (path: materialized.path, branch: "feat-x", head: nil),
      ]
    )

    await store.send(.pendingWorktreeFinished(id, materialized))
    await store.skipInFlightEffects()

    let rows = manager.catalog.projects[0].worktrees
    #expect(rows.map(\.path) == ["/repo", materialized.path, "/repo/.worktrees/older"])
    #expect(rows.last?.id == olderID)
    #expect(rows[1].name == "feat/x")
    #expect(!manager.holdsCreationLease(projectID))
    #expect(releasedProjects == [projectID])
  }

  // MARK: - Release on every exit path

  @Test
  func beginTakesTheLeaseAndFinishReleasesIt() async {
    let pending = Self.makePending(projectID: ProjectID())
    let events = LockIsolated<[LeaseEvent]>([])
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      Self.record(events, into: &$0)
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
      $0.gitWorktreeClient.createWorktreeStream = { _ in
        AsyncThrowingStream {
          $0.yield(.finished(worktreePath: URL(fileURLWithPath: "/repo/.worktrees/feat-x")))
          $0.finish()
        }
      }
      $0.hierarchyClient.createWorktreeWithGit = { _, _, _, _ in WorktreeID() }
    }
    store.exhaustivity = .off

    await store.send(.beginPendingWorktreeCreation(pending))
    await store.receive(\.pendingWorktreeFinished)
    await store.skipReceivedActions()

    let lease = Self.lease(for: pending)
    #expect(events.value == [.begin(lease), .end(lease)])
  }

  @Test
  func catalogWriteFailureReleasesTheLease() async {
    let pending = Self.makePending(projectID: ProjectID())
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)
    let events = LockIsolated<[LeaseEvent]>([])
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      Self.record(events, into: &$0)
      $0.hierarchyClient.createWorktreeWithGit = { _, _, _, _ in
        throw GitWorktreeError.commandFailed(command: "catalog", stderr: "boom")
      }
    }
    store.exhaustivity = .off

    await store.send(
      .pendingWorktreeFinished(pending.id, URL(fileURLWithPath: "/repo/.worktrees/feat-x")))

    #expect(events.value == [.end(Self.lease(for: pending))])
    #expect(store.state.pendingWorktrees[id: pending.id]?.status != .running)
  }

  @Test
  func streamFailureReleasesTheLease() async {
    let pending = Self.makePending(projectID: ProjectID())
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)
    let events = LockIsolated<[LeaseEvent]>([])
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      Self.record(events, into: &$0)
    }
    store.exhaustivity = .off

    await store.send(.pendingWorktreeFailed(pending.id, .commandFailed(command: "git", stderr: "x")))

    #expect(events.value == [.end(Self.lease(for: pending))])
  }

  @Test
  func cancelDuringGitAddReleasesTheLease() async {
    let pending = Self.makePending(projectID: ProjectID())
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)
    let events = LockIsolated<[LeaseEvent]>([])
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      Self.record(events, into: &$0)
    }

    await store.send(.pendingWorktreeCancelTapped(pending.id)) {
      $0.pendingWorktrees.remove(id: pending.id)
    }

    #expect(events.value == [.end(Self.lease(for: pending))])
  }

  @Test
  func cancelDuringSetupReleasesTheLeaseAfterTheCatalogWrite() async {
    var pending = Self.makePending(projectID: ProjectID())
    let materialized = URL(fileURLWithPath: "/repo/.worktrees/feat-x")
    pending.phase = .runningSetupScript
    pending.materializedPath = materialized
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)
    let events = LockIsolated<[LeaseEvent]>([])
    let wroteBeforeRelease = LockIsolated<Bool?>(nil)
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      Self.record(events, into: &$0)
      $0.hierarchyClient.createWorktreeWithGit = { _, _, _, _ in
        wroteBeforeRelease.setValue(events.value.isEmpty)
        return WorktreeID()
      }
    }
    store.exhaustivity = .off

    await store.send(.pendingWorktreeCancelTapped(pending.id))
    await store.receive(\.pendingWorktreeFinished)
    await store.skipReceivedActions()

    #expect(wroteBeforeRelease.value == true)
    #expect(events.value == [.end(Self.lease(for: pending))])
  }

  @Test
  func retryRetakesTheLeaseAndDiscardReleasesIt() async {
    let pending = Self.makePending(
      projectID: ProjectID(), status: .failed(.commandFailed(command: "git", stderr: "x")))
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorktrees.append(pending)
    let events = LockIsolated<[LeaseEvent]>([])
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      Self.record(events, into: &$0)
      $0.gitWorktreeClient.createWorktreeStream = { _ in
        AsyncThrowingStream {
          $0.finish(throwing: GitWorktreeError.commandFailed(command: "git", stderr: "again"))
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.pendingWorktreeRetryTapped(pending.id))
    await store.receive(\.pendingWorktreeFailed)
    await store.send(.pendingWorktreeDiscardTapped(pending.id))

    let lease = Self.lease(for: pending)
    #expect(events.value == [.begin(lease), .end(lease), .end(lease)])
    #expect(store.state.pendingWorktrees[id: pending.id] == nil)
  }
}
