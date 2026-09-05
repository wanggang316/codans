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

  private static func makeState(isInstalled: (AgentKind) -> Bool = { _ in true }) -> HandoffFeature.State {
    HandoffFeature.State.make(
      source: source,
      profiles: [
        codexProfile,
        AgentProfile(kind: .amp),  // no prompt argument → kickoff is typed in
        AgentProfile(kind: .claudeCode, isEnabled: false),  // disabled → not a receiver
      ],
      isInstalled: isInstalled
    )
  }

  @Test
  func targetsAreTheEnabledProfilesPlusTheCheckpointRow() {
    let state = Self.makeState()
    #expect(
      state.targets.map(\.title) == ["Build", AgentKind.amp.displayName, "Only save progress, don't hand off"])
    #expect(state.targets.first?.profile?.id == Self.codexProfile.id)
    #expect(state.targets.last?.kind == .checkpoint)
    #expect(state.targets.first?.isSameAgent == false)
    // The tooltip tells the user how the prompt reaches an agent without one.
    #expect(state.targets[0].help.contains("typed in") == false)
    #expect(state.targets[1].help.contains("kickoff typed in"))

    let same = HandoffFeature.State.make(source: Self.source, profiles: [AgentProfile(kind: .claudeCode)])
    #expect(same.targets.first?.isSameAgent == true)
  }

  /// Same rule as the toolbar Agents menu: agents the shell could not resolve
  /// are hidden, unless that would hide every one of them.
  @Test
  func agentsTheMachineCannotRunAreHiddenUnlessThatWouldHideAll() {
    let filtered = Self.makeState(isInstalled: { $0 != .amp })
    #expect(filtered.targets.map(\.title) == ["Build", "Only save progress, don't hand off"])

    let failedOpen = Self.makeState(isInstalled: { _ in false })
    #expect(failedOpen.targets.count == 3)
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

  /// The placement rides on the typed command, is remembered through the
  /// client, and reaches the context-only fallback as wire fields.
  @Test
  func placementIsRememberedAndTravelsWithBothPaths() async {
    let remembered = LockIsolated<[HandoffPlacement]>([])
    let typed = LockIsolated<[String]>([])
    let ran = LockIsolated<[IPC.HandoffRequest]>([])
    let fallback = HandoffCompletion(
      action: .to, sourcePaneID: Self.paneID, receiver: .codex, briefing: .none,
      launched: nil, requestID: nil)

    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    } withDependencies: {
      $0.uuid = .constant(Self.requestID)
      $0.handoffClient.cli = "codans"
      $0.handoffClient.rememberPlacement = { placement in remembered.withValue { $0.append(placement) } }
      $0.handoffClient.register = { _ in }
      $0.handoffClient.completions = { AsyncStream { $0.finish() } }
      $0.handoffClient.sendInstruction = { _, text in
        typed.withValue { $0.append(text) }
        return false
      }
      $0.handoffClient.supersede = { _ in true }
      $0.handoffClient.run = { request in
        ran.withValue { $0.append(request) }
        return fallback
      }
    }

    await store.send(.setPlacement(.split(.right))) { state in
      state.placement = .split(.right)
    }
    // Re-choosing the same placement is not a change worth recording.
    await store.send(.setPlacement(.split(.right)))
    #expect(remembered.value == [.split(.right)])

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
    #expect(typed.value.first?.contains("codans handoff to codex --split right --brief -") == true)
    #expect(ran.value.first?.target == .split)
    #expect(ran.value.first?.direction == .right)

    // Frozen once running.
    await store.send(.setPlacement(.newTab))
  }

  @Test
  func placementOpensOnTheRememberedChoice() {
    let state = HandoffFeature.State.make(source: Self.source, profiles: [Self.codexProfile], placement: .split(.down))
    #expect(state.placement == .split(.down))
    #expect(Self.makeState().placement == .newTab)
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
    state.selectedIndex = 2  // checkpoint row, after Build and Amp
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
        HandoffFeature.Run(target: state.targets[2], requestID: Self.requestID, stage: .requesting))
    }
    await store.send(.contextOnlyTapped) { state in
      state.phase = .running(
        HandoffFeature.Run(target: state.targets[2], requestID: Self.requestID, stage: .finishing))
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
  func selectionWalksTheGridAndIsFrozenOnceRunning() async {
    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    }
    // One grid row (Build, Amp) over the checkpoint. Left/right walk the list
    // and wrap; down from the row lands on the checkpoint, down again wraps
    // to the top, up from the top wraps to the checkpoint.
    await store.send(.moveSelection(.left)) { $0.selectedIndex = 2 }
    await store.send(.moveSelection(.right)) { $0.selectedIndex = 0 }
    await store.send(.moveSelection(.right)) { $0.selectedIndex = 1 }
    await store.send(.moveSelection(.down)) { $0.selectedIndex = 2 }
    await store.send(.moveSelection(.down)) { $0.selectedIndex = 0 }
    await store.send(.moveSelection(.up)) { $0.selectedIndex = 2 }
    await store.send(.moveSelection(.up)) { $0.selectedIndex = 1 }
    await store.send(.setSelectedIndex(5))
    await store.send(.cancelTapped)
    await store.receive(.delegate(.dismiss))
  }

  /// Up/down step a whole grid row, and the checkpoint is the row below the
  /// last profile even when that row is not full.
  @Test
  func verticalMovesStepByGridRow() {
    var state = HandoffFeature.State.make(
      source: Self.source,
      profiles: [Self.codexProfile, AgentProfile(kind: .amp), AgentProfile(kind: .gemini)])
    // Grid: [Build, Amp] / [Gemini] / checkpoint
    #expect(state.index(moving: .down) == 2)
    state.selectedIndex = 1
    #expect(state.index(moving: .down) == 3)
    state.selectedIndex = 2
    #expect(state.index(moving: .down) == 3)
    #expect(state.index(moving: .up) == 0)
    state.selectedIndex = 3
    #expect(state.index(moving: .up) == 2)
    #expect(state.index(moving: .down) == 0)
  }
}
