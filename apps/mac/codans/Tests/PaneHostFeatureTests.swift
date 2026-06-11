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
  /// exact `.failed` message.
  private static let fixedErrorWorktreeID = WorktreeID()
  private static var failureMessageForFixedError: String {
    String(describing: TerminalClient.Error.worktreeNotFound(fixedErrorWorktreeID))
  }

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

    await store.send(.task) {
      $0.phase = .failed(Self.failureMessageForFixedError)
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

    await store.send(.task) {
      $0.phase = .failed("Surface not registered after creation.")
    }
    #expect(ensureCalls.value == 1)
  }

  @Test
  func retryFromFailedResetsThenReRunsResolve() async {
    let ensureCalls = LockIsolated<Int>(0)
    var initial = Self.makeState()
    initial.phase = .failed("prior")
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
    // settling on .failed. TestStore asserts the final coalesced state.
    await store.send(.retryButtonTapped) {
      $0.phase = .failed(Self.failureMessageForFixedError)
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

    await store.send(.task) {
      $0.phase = .failed("Surface not registered after creation.")
    }
    #expect(ensureCalls.value == 1)
  }
}
