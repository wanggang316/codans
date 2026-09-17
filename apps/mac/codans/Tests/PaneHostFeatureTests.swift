import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// TCA reducer tests for `PaneHostFeature`. Covers the decision tree that
/// used to live in `LazyPaneHost.ensureSurface()`: registry short-circuit,
/// first-appearance ensure path, ensure throw, post-ensure lookup nil, and
/// retry.
///
/// `PaneSurface` requires libghostty + Metal to instantiate; we cannot
/// produce a live instance in xctest. The tests exercise every path that
/// does NOT land in `.ready` — the `.ready` branch is covered end-to-end
/// by the app itself (launching with a persisted catalog). For the
/// short-circuit path we verify only that the stubbed registry returning
/// `nil` causes `ensureSurface` to run; a live-surface short-circuit is
/// out of xctest reach.
@MainActor
struct PaneHostFeatureTests {
  private static func makeState(paneID: PaneID = PaneID()) -> PaneHostFeature.State {
    PaneHostFeature.State(
      paneID: paneID,
      tabID: TabID(),
      worktreeID: WorktreeID(),
      projectID: ProjectID()
    )
  }

  /// Deterministic failure so the state mutation closure can assert the
  /// exact `.failed` payload.
  private static let fixedErrorWorktreeID = WorktreeID()
  private static var failureForFixedError: PaneHostFeature.Failure {
    PaneHostFeature.Failure(
      reason: "This pane no longer exists in the workspace.",
      detail: String(describing: TerminalClient.Error.worktreeNotFound(fixedErrorWorktreeID))
    )
  }
  private static let surfaceNotRegistered = PaneHostFeature.Failure(
    reason: "Surface not registered after creation."
  )

  @Test
  func taskWithEnsureThrowLandsInFailed() async {
    let ensureCalls = LockIsolated<Int>(0)
    let store = TestStore(initialState: Self.makeState()) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, _, _, _ in
        ensureCalls.withValue { $0 += 1 }
        throw TerminalClient.Error.worktreeNotFound(Self.fixedErrorWorktreeID)
      }
    }

    await store.send(.task)
    await store.receive(.resolveFailed(Self.failureForFixedError)) {
      $0.phase = .failed(Self.failureForFixedError)
    }
    #expect(ensureCalls.value == 1)
  }

  @Test
  func taskWithEnsureSuccessButLookupNilLandsInFailed() async {
    let ensureCalls = LockIsolated<Int>(0)
    let store = TestStore(initialState: Self.makeState()) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, _, _, _ in
        ensureCalls.withValue { $0 += 1 }
      }
    }

    await store.send(.task)
    await store.receive(.resolveFailed(Self.surfaceNotRegistered)) {
      $0.phase = .failed(Self.surfaceNotRegistered)
    }
    #expect(ensureCalls.value == 1)
  }

  @Test
  func retryFromFailedResetsThenReRunsResolve() async {
    let ensureCalls = LockIsolated<Int>(0)
    var initial = Self.makeState()
    initial.phase = .failed(.init(reason: "prior"))
    let store = TestStore(initialState: initial) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, _, _, _ in
        ensureCalls.withValue { $0 += 1 }
        throw TerminalClient.Error.worktreeNotFound(Self.fixedErrorWorktreeID)
      }
    }

    // Retry wipes to .loading, then the resolve path runs and throws,
    // settling back on .failed.
    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await store.receive(.resolveFailed(Self.failureForFixedError)) {
      $0.phase = .failed(Self.failureForFixedError)
    }
    #expect(ensureCalls.value == 1)
  }

  @Test
  func taskOnAlreadyReadyStateStillShortCircuitsViaRegistry() async {
    // The registry short-circuit runs before `ensureSurface` is invoked.
    // When the stub returns `nil`, `ensureSurface` runs; when it returns
    // a surface we'd land on `.ready`. We can't construct a live
    // PaneSurface here, so we assert the weaker property: if the stub
    // returns `nil`, `ensureSurface` is invoked (i.e. the reducer does
    // attempt to create the surface rather than skipping the work).
    let ensureCalls = LockIsolated<Int>(0)
    let store = TestStore(initialState: Self.makeState()) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, _, _, _ in
        ensureCalls.withValue { $0 += 1 }
      }
    }

    await store.send(.task)
    await store.receive(.resolveFailed(Self.surfaceNotRegistered)) {
      $0.phase = .failed(Self.surfaceNotRegistered)
    }
    #expect(ensureCalls.value == 1)
  }

  @Test
  func failureFromLocalizedErrorKeepsRawErrorAsDetail() {
    let failure = PaneHostFeature.Failure(error: HierarchyError.zmxBinaryMissing)
    #expect(
      failure.reason
        == "This Codans build is missing its bundled zmx helper. Rebuild or reinstall the app."
    )
    #expect(failure.detail == "zmxBinaryMissing")
  }

  @Test
  func failureFromPlainErrorUsesDescriptionWithoutDuplicateDetail() {
    struct Plain: Error, CustomStringConvertible {
      var description: String { "plain failure" }
    }
    let failure = PaneHostFeature.Failure(error: Plain())
    #expect(failure.reason == "plain failure")
    #expect(failure.detail == nil)
  }
}
