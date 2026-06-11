import ComposableArchitecture
import Foundation
import CodansCore

/// Drives per-Project health reconciliation. Stats the `rootPath`, labels the
/// Project `.failed(reason:)` when the folder is gone, otherwise hands off to
/// `HierarchyClient.reconcileDiscoveredWorktrees` (owned by T-WORKTREE;
/// append-only / idempotent / swallows errors / main-actor serialized) and
/// flips the load state to `.ready`.
///
/// The actor does not import `GitWorktreeCLI`; worktree-list discovery is
/// entirely the responsibility of the consumed closure. See
/// `docs/design-docs/pm-project-management.md` §Boundary with T-WORKTREE.
///
/// Single-flight by `ProjectID` and debounced at the `reconcileAll` entry
/// point so focus-change notification storms do not fan out into N calls.
actor ProjectReconciler {
  private let client: HierarchyClient
  private let now: @Sendable () -> Date
  private let debounceInterval: TimeInterval
  private var inFlight: Set<ProjectID> = []
  private var lastAllRun: Date?

  /// `now` is injected as a closure rather than threading `any Clock<Duration>`
  /// because (a) we need no sleep/timer — only a monotonic "is the window past?"
  /// check, (b) storing an `any Clock`'s `Instant` as actor state forces
  /// generics for no behavioral gain, and (c) a `Date`-returning closure is
  /// trivial to script in tests (`now: { fixedDate }` and advance it between
  /// calls).
  init(
    client: HierarchyClient,
    now: @escaping @Sendable () -> Date = Date.init,
    debounceInterval: TimeInterval = 10.0
  ) {
    self.client = client
    self.now = now
    self.debounceInterval = debounceInterval
  }

  /// Reconcile a single Project. Single-flight per `ProjectID`; overlapping
  /// calls early-return. The missing-Project branch is also a silent no-op
  /// (the Project may have been removed between the caller's snapshot and
  /// this call).
  func reconcile(projectID: ProjectID) async {
    guard !inFlight.contains(projectID) else { return }
    inFlight.insert(projectID)
    defer { inFlight.remove(projectID) }

    let snapshot = await client.snapshot()
    guard let project = snapshot.projects.first(where: { $0.id == projectID })
    else {
      return
    }

    await client.setProjectLoadState(projectID, .loading)

    guard FileManager.default.fileExists(atPath: project.rootPath) else {
      await client.setProjectLoadState(
        projectID,
        .failed(reason: "Folder no longer exists at \(project.rootPath)")
      )
      return
    }

    // T-WORKTREE's closure handles git-vs-non-git routing, `GitWorktreeCLI`
    // orchestration, error recovery, and the append-only mutation of
    // `project.worktrees`. Per its contract it does not throw; the Project
    // lands in `.ready` unconditionally after the call returns.
    await client.reconcileDiscoveredWorktrees(projectID)
    await client.setProjectLoadState(projectID, .ready)
  }

  /// Fan out across all Projects in the current snapshot. Debounced by
  /// `debounceInterval` — repeated calls within the window are dropped.
  /// Per-project single-flight inside `reconcile` absorbs the case where a
  /// debounce window closes while a prior `reconcileAll` is still running.
  ///
  /// `force: true` bypasses the debounce — wired to the sidebar's manual
  /// refresh button so the user-initiated "refresh now" never waits out
  /// the focus-driven cadence. Per-project single-flight still protects
  /// against double-runs.
  func reconcileAll(force: Bool = false) async {
    let current = now()
    if !force, let last = lastAllRun, current.timeIntervalSince(last) < debounceInterval {
      return
    }
    lastAllRun = current

    let snapshot = await client.snapshot()
    await withTaskGroup(of: Void.self) { group in
      for project in snapshot.projects {
        let pid = project.id
        group.addTask { [self] in
          await reconcile(projectID: pid)
        }
      }
    }
  }
}

extension ProjectReconciler: DependencyKey {
  /// Unconfigured fallback reconciler used when the app has not yet installed
  /// the real one in `CodansApp.bringUp` via `.withDependencies`, and for
  /// tests that don't exercise reconcile. Its captured `HierarchyClient` is
  /// a no-op overlay over `.testValue` whose snapshot returns an empty
  /// Catalog, so `reconcileAll` fans out across zero Projects and the two
  /// write closures (`setProjectLoadState`, `reconcileDiscoveredWorktrees`)
  /// don't record `unimplemented(...)` issues.
  ///
  /// Accessed on MainActor in practice (TCA reducer wiring, SwiftUI view
  /// graph); `assumeIsolated` crashes loudly with a clear message if ever
  /// accessed off the main thread rather than risking UB.
  static var liveValue: ProjectReconciler {
    MainActor.assumeIsolated {
      var noop = HierarchyClient.testValue
      noop.snapshot = { Catalog() }
      noop.setProjectLoadState = { _, _ in }
      noop.reconcileDiscoveredWorktrees = { _ in }
      return ProjectReconciler(client: noop)
    }
  }

  /// The TCA default `testValue` calls `unimplemented(...)` and records an
  /// issue on every access, which would trip `@Dependency(ProjectReconciler.self)`
  /// in tests that don't actually exercise reconcile. Point at the same no-op
  /// reconciler used by `liveValue` so `.onLaunch` test paths stay clean;
  /// tests that do care about reconcile behavior override the dependency
  /// explicitly.
  static var testValue: ProjectReconciler { liveValue }
}

extension DependencyValues {
  var projectReconciler: ProjectReconciler {
    get { self[ProjectReconciler.self] }
    set { self[ProjectReconciler.self] = newValue }
  }
}
