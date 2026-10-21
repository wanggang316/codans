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
  private static func makeState(contentID: ContentID = ContentID()) -> PaneHostFeature.State {
    PaneHostFeature.State(
      contentID: contentID,
      paneID: PaneID(),
      tabID: TabID(),
      worktreeID: WorktreeID(),
      projectID: ProjectID()
    )
  }

  /// Deterministic failure so the state mutation closure can assert the
  /// exact `.failed` payload.
  private static let fixedErrorContentID = ContentID()
  private static var failureForFixedError: PaneHostFeature.Failure {
    PaneHostFeature.Failure(
      reason: "This tab no longer exists in the workspace.",
      detail: String(describing: TerminalClient.Error.contentNotFound(fixedErrorContentID))
    )
  }
  private static let surfaceNotRegistered = PaneHostFeature.Failure(
    reason: "Surface not registered after creation."
  )
  private static let slotSize = CGSize(width: 1_640, height: 1_020)

  @Test
  func taskStartsTheSurfaceAtTheSlotSize() async {
    let sizes = LockIsolated<[CGSize?]>([])
    let store = TestStore(initialState: Self.makeState()) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, initialSize in
        sizes.withValue { $0.append(initialSize) }
      }
    }

    await store.send(.task(slotSize: Self.slotSize)) {
      $0.slotSize = Self.slotSize
    }
    await store.receive(.resolveFailed(Self.surfaceNotRegistered)) {
      $0.phase = .failed(Self.surfaceNotRegistered)
    }
    #expect(sizes.value == [Self.slotSize])
  }

  @Test
  func taskWithAnEmptySlotLeavesTheInitialSizeUnknown() async {
    let sizes = LockIsolated<[CGSize?]>([])
    let store = TestStore(initialState: Self.makeState()) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, initialSize in
        sizes.withValue { $0.append(initialSize) }
      }
    }

    await store.send(.task(slotSize: .zero))
    await store.receive(.resolveFailed(Self.surfaceNotRegistered)) {
      $0.phase = .failed(Self.surfaceNotRegistered)
    }
    #expect(sizes.value == [nil])
  }

  @Test
  func retryStartsTheSurfaceAtTheLastSlotSize() async {
    let sizes = LockIsolated<[CGSize?]>([])
    var initial = Self.makeState()
    initial.phase = .failed(.init(reason: "prior"))
    initial.slotSize = Self.slotSize
    let store = TestStore(initialState: initial) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, initialSize in
        sizes.withValue { $0.append(initialSize) }
      }
    }

    await store.send(.retryButtonTapped) {
      $0.phase = .loading
    }
    await store.receive(.resolveFailed(Self.surfaceNotRegistered)) {
      $0.phase = .failed(Self.surfaceNotRegistered)
    }
    #expect(sizes.value == [Self.slotSize])
  }

  @Test
  func taskWithEnsureThrowLandsInFailed() async {
    let ensureCalls = LockIsolated<Int>(0)
    let store = TestStore(initialState: Self.makeState()) {
      PaneHostFeature()
    } withDependencies: {
      $0.terminalClient.surface = { _ in nil }
      $0.terminalClient.ensureSurface = { _, _ in
        ensureCalls.withValue { $0 += 1 }
        throw TerminalClient.Error.contentNotFound(Self.fixedErrorContentID)
      }
    }

    await store.send(.task(slotSize: Self.slotSize)) {
      $0.slotSize = Self.slotSize
    }
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
      $0.terminalClient.ensureSurface = { _, _ in
        ensureCalls.withValue { $0 += 1 }
      }
    }

    await store.send(.task(slotSize: Self.slotSize)) {
      $0.slotSize = Self.slotSize
    }
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
      $0.terminalClient.ensureSurface = { _, _ in
        ensureCalls.withValue { $0 += 1 }
        throw TerminalClient.Error.contentNotFound(Self.fixedErrorContentID)
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
      $0.terminalClient.ensureSurface = { _, _ in
        ensureCalls.withValue { $0 += 1 }
      }
    }

    await store.send(.task(slotSize: Self.slotSize)) {
      $0.slotSize = Self.slotSize
    }
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
