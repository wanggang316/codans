import Foundation
import Testing
import CodansCore

@testable import Codans

/// Recorder-driven tests for `ProjectReconciler`. The `HierarchyClient`
/// closures this actor calls are replaced with a `LockIsolated` recorder;
/// no real `GitWorktreeCLI` fixture is used because worktree-list mutation
/// is delegated to `reconcileDiscoveredWorktrees` (T-WORKTREE's closure).
/// That keeps this test surface immune to the T-WORKTREE rebase — the
/// recorder doesn't care what the real implementation does.
struct ProjectReconcilerTests {
  // MARK: - Recorder

  /// Captures every closure invocation the reconciler makes against
  /// `HierarchyClient`. `Sendable` via `LockIsolated` so the actor can
  /// safely push events from any executor.
  final class Recorder: @unchecked Sendable {
    enum Event: Equatable {
      case setLoadState(ProjectID, ProjectLoadState)
      case reconcileDiscovered(ProjectID)
    }

    private let lock = NSLock()
    private var _events: [Event] = []

    var events: [Event] {
      lock.lock()
      defer { lock.unlock() }
      return _events
    }

    func append(_ event: Event) {
      lock.lock()
      _events.append(event)
      lock.unlock()
    }

    func reconcileDiscoveredCount() -> Int {
      events.filter {
        if case .reconcileDiscovered = $0 { return true } else { return false }
      }.count
    }
  }

  /// Build a `HierarchyClient` whose Project-level closures wire into a
  /// recorder, snapshot returns the scripted catalog, and everything else
  /// falls back to `unimplemented` (the reconciler never touches them).
  @MainActor
  private static func makeClient(
    catalog: @escaping @Sendable () -> Catalog,
    recorder: Recorder,
    reconcileDelayNanos: UInt64 = 0
  ) -> HierarchyClient {
    var client = HierarchyClient.testValue
    client.snapshot = { catalog() }
    client.setProjectLoadState = { projectID, state in
      recorder.append(.setLoadState(projectID, state))
    }
    client.reconcileDiscoveredWorktrees = { projectID in
      if reconcileDelayNanos > 0 {
        try? await Task.sleep(nanoseconds: reconcileDelayNanos)
      }
      recorder.append(.reconcileDiscovered(projectID))
    }
    return client
  }

  /// Builds a one-Project catalog with the given `rootPath`.
  private static func makeCatalog(rootPath: String) -> (Catalog, ProjectID) {
    let projectID = ProjectID()
    let project = Project(
      id: projectID,
      name: "p",
      rootPath: rootPath,
      gitRoot: rootPath
    )
    let catalog = Catalog(projects: [project])
    return (catalog, projectID)
  }

  private static func withTempDir<T>(_ body: (String) async throws -> T) async rethrows -> T {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url.path)
  }

  // MARK: - Tests

  @Test
  func reconcileExistingFolderCallsClosureAndSetsReady() async throws {
    try await Self.withTempDir { rootPath in
      let (catalog, projectID) = Self.makeCatalog(rootPath: rootPath)
      let recorder = Recorder()
      let client = await Self.makeClient(catalog: { catalog }, recorder: recorder)
      let reconciler = ProjectReconciler(client: client)

      await reconciler.reconcile(projectID: projectID)

      #expect(
        recorder.events == [
          .setLoadState(projectID, .loading),
          .reconcileDiscovered(projectID),
          .setLoadState(projectID, .ready),
        ])
    }
  }

  @Test
  func reconcileMissingFolderSetsFailedAndSkipsClosure() async {
    let missingPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("pm-reconciler-absent-\(UUID().uuidString)").path
    let (catalog, projectID) = Self.makeCatalog(rootPath: missingPath)
    let recorder = Recorder()
    let client = await Self.makeClient(catalog: { catalog }, recorder: recorder)
    let reconciler = ProjectReconciler(client: client)

    await reconciler.reconcile(projectID: projectID)

    // Exactly two events: .loading → .failed. No reconcileDiscovered call.
    #expect(recorder.events.count == 2)
    if case .setLoadState(_, let state) = recorder.events.last {
      if case .failed(let reason) = state {
        #expect(reason.contains("Folder no longer exists"))
        #expect(reason.contains(missingPath))
      } else {
        Issue.record("Expected .failed load state, got \(state)")
      }
    } else {
      Issue.record("Expected .setLoadState as last event")
    }
    #expect(recorder.reconcileDiscoveredCount() == 0)
  }

  @Test
  func reconcileUnknownProjectIsSilentNoOp() async {
    let recorder = Recorder()
    let emptyCatalog = Catalog()
    let client = await Self.makeClient(catalog: { emptyCatalog }, recorder: recorder)
    let reconciler = ProjectReconciler(client: client)

    await reconciler.reconcile(projectID: ProjectID())

    #expect(recorder.events.isEmpty)
  }

  @Test
  func reconcileSingleFlightDedupsOverlappingCalls() async throws {
    try await Self.withTempDir { rootPath in
      let (catalog, projectID) = Self.makeCatalog(rootPath: rootPath)
      let recorder = Recorder()
      // Artificial delay inside the consumed closure so concurrent calls
      // overlap before the first one completes.
      let client = await Self.makeClient(
        catalog: { catalog },
        recorder: recorder,
        reconcileDelayNanos: 50_000_000  // 50ms — long enough to overlap.
      )
      let reconciler = ProjectReconciler(client: client)

      async let first: Void = reconciler.reconcile(projectID: projectID)
      async let second: Void = reconciler.reconcile(projectID: projectID)
      _ = await (first, second)

      // Single flight: second call must early-return inside the actor before
      // inserting duplicates into the recorder.
      #expect(recorder.reconcileDiscoveredCount() == 1)
    }
  }

  @Test
  func reconcileAllDebouncesWithinWindow() async throws {
    try await Self.withTempDir { rootPath in
      let (catalog, _) = Self.makeCatalog(rootPath: rootPath)
      let recorder = Recorder()
      let client = await Self.makeClient(catalog: { catalog }, recorder: recorder)

      // Controlled clock — driven by the test, not the wall.
      let clockState = LockedDate(date: Date(timeIntervalSince1970: 1000))
      let reconciler = ProjectReconciler(
        client: client,
        now: { clockState.current() },
        debounceInterval: 2.0
      )

      await reconciler.reconcileAll()
      let afterFirst = recorder.reconcileDiscoveredCount()
      #expect(afterFirst == 1)

      // Advance by 1s — still inside the 2s debounce window. reconcileAll
      // returns immediately; no new closure invocations.
      clockState.advance(1.0)
      await reconciler.reconcileAll()
      #expect(recorder.reconcileDiscoveredCount() == afterFirst)

      // Advance past the window.
      clockState.advance(1.5)
      await reconciler.reconcileAll()
      #expect(recorder.reconcileDiscoveredCount() == afterFirst + 1)
    }
  }

  /// Manual refresh from the sidebar must run even while the debounce
  /// window is open — otherwise a focus-driven sweep that landed seconds
  /// before the user's click would silently swallow the click.
  @Test
  func reconcileAllForceBypassesDebounce() async throws {
    try await Self.withTempDir { rootPath in
      let (catalog, _) = Self.makeCatalog(rootPath: rootPath)
      let recorder = Recorder()
      let client = await Self.makeClient(catalog: { catalog }, recorder: recorder)
      let clockState = LockedDate(date: Date(timeIntervalSince1970: 1000))
      let reconciler = ProjectReconciler(
        client: client,
        now: { clockState.current() },
        debounceInterval: 2.0
      )

      await reconciler.reconcileAll()
      let afterFirst = recorder.reconcileDiscoveredCount()
      #expect(afterFirst == 1)

      // Stay inside the debounce window; without `force`, the second call
      // would be dropped.
      clockState.advance(0.5)
      await reconciler.reconcileAll(force: true)
      #expect(recorder.reconcileDiscoveredCount() == afterFirst + 1)
    }
  }

  @Test
  func reconcileAllFansOutAcrossProjects() async throws {
    try await Self.withTempDir { rootA in
      try await Self.withTempDir { rootB in
        let a = Project(name: "a", rootPath: rootA, gitRoot: rootA)
        let b = Project(name: "b", rootPath: rootB, gitRoot: rootB)
        let catalog = Catalog(projects: [a, b])
        let recorder = Recorder()
        let client = await Self.makeClient(catalog: { catalog }, recorder: recorder)
        let reconciler = ProjectReconciler(client: client)

        await reconciler.reconcileAll()

        #expect(recorder.reconcileDiscoveredCount() == 2)
        let pids = recorder.events.compactMap { event -> ProjectID? in
          if case .reconcileDiscovered(let pid) = event { return pid }
          return nil
        }
        #expect(Set(pids) == Set([a.id, b.id]))
      }
    }
  }
}

/// Tiny Date holder so tests can advance the reconciler's clock deterministically.
private final class LockedDate: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(date: Date) { self.date = date }

  func current() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func advance(_ seconds: TimeInterval) {
    lock.lock()
    date = date.addingTimeInterval(seconds)
    lock.unlock()
  }
}
