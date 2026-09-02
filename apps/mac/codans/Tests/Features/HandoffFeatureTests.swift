import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The Hand Off panel's state machine: choose → ask the live agent → observe
/// the CLI completion (or fall back to context-only) → finish. Every effect
/// goes through `HandoffClient`, stubbed here.
@MainActor
struct HandoffFeatureTests {
  private static let paneID = PaneID()
  private static let requestID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
  private static let codexProfile = AgentProfile(kind: .codex, name: "Build")

  private static var source: HandoffFeature.Source {
    HandoffFeature.Source(
      paneID: paneID,
      projectID: ProjectID(raw: UUID()),
      worktreeID: WorktreeID(raw: UUID()),
      agent: .claudeCode
    )
  }

  private static func makeState() -> HandoffFeature.State {
    HandoffFeature.State.make(
      source: source,
      profiles: [
        codexProfile,
        AgentProfile(kind: .amp),  // no prompt style → not a receiver
        AgentProfile(kind: .claudeCode, isEnabled: false),  // disabled → not a receiver
      ]
    )
  }

  @Test
  func targetsAreThePromptCapableEnabledProfilesPlusTheCheckpointRow() {
    let state = Self.makeState()
    #expect(state.targets.map(\.title) == ["Build", "Only save progress, don't hand off"])
    #expect(state.targets.first?.profile?.id == Self.codexProfile.id)
    #expect(state.targets.last?.kind == .checkpoint)
    #expect(state.targets.first?.isSameAgent == false)

    let same = HandoffFeature.State.make(source: Self.source, profiles: [AgentProfile(kind: .claudeCode)])
    #expect(same.targets.first?.isSameAgent == true)
  }

  @Test
  func confirmingTypesTheRequestAndFinishesOnTheMatchingCompletion() async {
    let (completions, continuation) = AsyncStream<HandoffCompletion>.makeStream()
    let registered = LockIsolated<[UUID]>([])
    let typed = LockIsolated<[(PaneID, String)]>([])

    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    } withDependencies: {
      $0.uuid = .constant(Self.requestID)
      $0.handoffClient.register = { id in registered.withValue { $0.append(id) } }
      $0.handoffClient.completions = { completions }
      $0.handoffClient.sendInstruction = { pane, text in
        typed.withValue { $0.append((pane, text)) }
        return true
      }
    }

    await store.send(.confirmSelection) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[0], requestID: Self.requestID, stage: .requesting))
    }
    #expect(registered.value == [Self.requestID])
    #expect(typed.value.first?.0 == Self.paneID)
    #expect(
      typed.value.first?.1
        == HandoffKickoff.sourceInstruction(for: .handOff(to: .codex), requestID: Self.requestID))

    // A completion for some other request is ignored.
    let stranger = HandoffCompletion(
      action: .to, sourcePaneID: Self.paneID, receiver: .codex, briefing: .inline,
      launched: nil, requestID: UUID())
    continuation.yield(stranger)
    await store.receive(.completionReceived(stranger))

    let launched = IPC.HandoffLaunchedPane(
      projectID: Self.source.projectID, worktreeID: Self.source.worktreeID,
      tabID: TabID(), paneID: PaneID(), profileName: "Build")
    let mine = HandoffCompletion(
      action: .to, sourcePaneID: Self.paneID, receiver: .codex, briefing: .inline,
      launched: launched, requestID: Self.requestID)
    continuation.yield(mine)
    await store.receive(.completionReceived(mine)) { state in
      state.phase = .finished(.handedOff(profileName: "Build"))
    }
    await store.receive(.delegate(.focusPane(launched.paneID)))
    continuation.finish()

    await store.send(.closeTapped)
    await store.receive(.delegate(.dismiss))
  }

  @Test
  func undeliverableRequestFallsBackToContextOnly() async {
    let superseded = LockIsolated<[UUID]>([])
    let ran = LockIsolated<[IPC.HandoffRequest]>([])
    let fallback = HandoffCompletion(
      action: .to, sourcePaneID: Self.paneID, receiver: .codex, briefing: .none,
      launched: nil, requestID: nil)

    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    } withDependencies: {
      $0.uuid = .constant(Self.requestID)
      $0.handoffClient.register = { _ in }
      $0.handoffClient.completions = { AsyncStream { $0.finish() } }
      $0.handoffClient.sendInstruction = { _, _ in false }
      $0.handoffClient.supersede = { id in
        superseded.withValue { $0.append(id) }
        return true
      }
      $0.handoffClient.run = { request in
        ran.withValue { $0.append(request) }
        return fallback
      }
    }

    await store.send(.confirmSelection) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[0], requestID: Self.requestID, stage: .requesting))
    }
    await store.receive(.deliveryFailed) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[0], requestID: Self.requestID, stage: .finishing))
    }
    await store.receive(.fallbackFinished(fallback)) { state in
      state.phase = .finished(.handedOff(profileName: "Build"))
    }
    #expect(superseded.value == [Self.requestID])
    let request = ran.value.first
    #expect(request?.action == .to)
    #expect(request?.contextOnly == true)
    #expect(request?.receiver == "codex")
    #expect(request?.profile == Self.codexProfile.id.uuidString)
    #expect(request?.requestID == nil)
  }

  @Test
  func contextOnlyWhileWaitingSupersedesTheRequestAndCheckpointsThroughSave() async {
    var state = Self.makeState()
    state.selectedIndex = 1  // checkpoint row
    let saved = HandoffCompletion(
      action: .save, sourcePaneID: Self.paneID, receiver: nil, briefing: .none,
      launched: nil, requestID: nil)
    let ran = LockIsolated<[IPC.HandoffRequest]>([])

    let store = TestStore(initialState: state) {
      HandoffFeature()
    } withDependencies: {
      $0.uuid = .constant(Self.requestID)
      $0.handoffClient.register = { _ in }
      $0.handoffClient.completions = { AsyncStream { _ in } }
      $0.handoffClient.sendInstruction = { _, _ in true }
      $0.handoffClient.supersede = { _ in true }
      $0.handoffClient.run = { request in
        ran.withValue { $0.append(request) }
        return saved
      }
    }

    await store.send(.confirmSelection) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[1], requestID: Self.requestID, stage: .requesting))
    }
    await store.send(.contextOnlyTapped) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[1], requestID: Self.requestID, stage: .finishing))
    }
    await store.receive(.fallbackFinished(saved)) { state in
      state.phase = .finished(.saved)
    }
    #expect(ran.value.first?.action == .save)
    #expect(ran.value.first?.contextOnly == true)
    // The fallback committed: cancel is a no-op from here.
    await store.send(.cancelTapped)
  }

  @Test
  func cancelWhileRequestingDismissesWithoutTouchingTheRequest() async {
    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    } withDependencies: {
      $0.uuid = .constant(Self.requestID)
      $0.handoffClient.register = { _ in }
      $0.handoffClient.completions = { AsyncStream { _ in } }
      $0.handoffClient.sendInstruction = { _, _ in true }
    }
    await store.send(.confirmSelection) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[0], requestID: Self.requestID, stage: .requesting))
    }
    await store.send(.cancelTapped)
    await store.receive(.delegate(.dismiss))
  }

  @Test
  func selectionWrapsAndIsFrozenOnceRunning() async {
    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    }
    await store.send(.moveSelection(delta: -1)) { $0.selectedIndex = 1 }
    await store.send(.moveSelection(delta: 1)) { $0.selectedIndex = 0 }
    await store.send(.setSelectedIndex(5))
    await store.send(.cancelTapped)
    await store.receive(.delegate(.dismiss))
  }
}
