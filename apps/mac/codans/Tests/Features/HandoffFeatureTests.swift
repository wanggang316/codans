import CodansCore
import CodansIPC
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The Hand Off chooser: which receivers it offers, how the grid is walked,
/// and the order it hands to the parent for Brief, Context, and Save Progress.
@MainActor
struct HandoffFeatureTests {
  private static let paneID = PaneID()
  private static let codexProfile = AgentProfile(kind: .codex, name: "Build")

  // Fixed ids: the delegate order is compared against this source.
  private static let source = HandoffFeature.Source(
    paneID: paneID,
    projectID: ProjectID(raw: UUID()),
    worktreeID: WorktreeID(raw: UUID()),
    agent: .claudeCode
  )

  private static func makeState(
    isInstalled: (AgentKind) -> Bool = { _ in true },
    placement: HandoffPlacement = .default
  ) -> HandoffFeature.State {
    HandoffFeature.State.make(
      source: source,
      profiles: [
        codexProfile,
        AgentProfile(kind: .amp),  // no prompt argument → kickoff is typed in
        AgentProfile(kind: .claudeCode, isEnabled: false),  // disabled → not a receiver
      ],
      isInstalled: isInstalled,
      placement: placement
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

  /// Hand Off with Brief hands the parent a brief order for the selected
  /// receiver, with the current placement; the panel does no work itself.
  @Test
  func confirmingOrdersABriefHandOffAndLeavesTheWorkToTheParent() async {
    let store = TestStore(initialState: Self.makeState(placement: .split(.down))) {
      HandoffFeature()
    }
    await store.send(.confirmSelection)
    await store.receive(
      .delegate(
        .handOff(
          source: Self.source,
          order: .brief(.handOff(to: .codex), targetTitle: "Build"),
          placement: .split(.down))))
  }

  @Test
  func theCheckpointRowOrdersASaveAndHasNoContextOnlyVariant() async {
    var state = Self.makeState()
    state.selectedIndex = 2  // checkpoint row, after Build and Amp
    let store = TestStore(initialState: state) {
      HandoffFeature()
    }
    await store.send(.confirmContextOnly)
    await store.send(.confirmSelection)
    await store.receive(
      .delegate(
        .handOff(
          source: Self.source,
          order: .brief(.checkpoint, targetTitle: "Only save progress, don't hand off"),
          placement: .newTab)))
  }

  @Test
  func contextOnlyOrdersTheSelectedProfileWithoutABriefing() async {
    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    }
    await store.send(.confirmContextOnly)
    await store.receive(
      .delegate(
        .handOff(
          source: Self.source,
          order: .contextOnly(profile: Self.codexProfile, targetTitle: "Build"),
          placement: .newTab)))
  }

  /// The placement is remembered through the client on every real change and
  /// opens on the remembered choice.
  @Test
  func placementIsRemembered() async {
    let remembered = LockIsolated<[HandoffPlacement]>([])
    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    } withDependencies: {
      $0.handoffClient.rememberPlacement = { placement in remembered.withValue { $0.append(placement) } }
    }
    await store.send(.setPlacement(.split(.right))) { state in
      state.placement = .split(.right)
    }
    // Re-choosing the same placement is not a change worth recording.
    await store.send(.setPlacement(.split(.right)))
    #expect(remembered.value == [.split(.right)])

    let reopened = HandoffFeature.State.make(
      source: Self.source, profiles: [Self.codexProfile], placement: .split(.down))
    #expect(reopened.placement == .split(.down))
    #expect(Self.makeState().placement == .newTab)
  }

  @Test
  func cancelDismisses() async {
    let store = TestStore(initialState: Self.makeState()) {
      HandoffFeature()
    }
    await store.send(.cancelTapped)
    await store.receive(.delegate(.dismiss))
  }

  @Test
  func selectionWalksTheGrid() async {
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

@MainActor
struct HandoffInputRoutingTests {
  @Test func instructionPreservesBytesAndRecordsExternalIntent() {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator()
    var writes: [String] = []
    let instruction = "Keep the existing prompt\nexactly as written."
    let result = HandoffClient.deliverInstruction(
      instruction, to: paneID, coordinator: coordinator, write: { writes.append($0) })
    #expect(result == .submitted)
    #expect(writes == [instruction + "\n"])
    #expect(coordinator.revision(for: paneID) == 1)
  }

  @Test func instructionRevokesRecoveryBeforePaste() async {
    let paneID = PaneID()
    let coordinator = PaneInputCoordinator()
    guard
      case .reserved(let lease) = coordinator.reserve(
        in: paneID, origin: .recovery(operationID: UUID()))
    else {
      Issue.record("Expected recovery lease")
      return
    }
    var writes: [String] = []
    let handoff = HandoffClient.deliverInstruction(
      "handoff", to: paneID, coordinator: coordinator, write: { writes.append($0) })
    let recovery = await coordinator.submitCommand(
      lease, paste: { writes.append("recovery") }, submit: { writes.append("return") })
    #expect(handoff == .submitted)
    #expect(recovery == .cancelledBeforeWrite)
    #expect(writes == ["handoff\n"])
  }

  @Test func instructionAfterRecoveryPastePreservesDraftAndRevokesReturn() async {
    let paneID = PaneID()
    var writes: [String] = []
    var handoff: SubmissionResult?
    var coordinator: PaneInputCoordinator!
    coordinator = PaneInputCoordinator(pauseBeforeSubmit: {
      handoff = HandoffClient.deliverInstruction(
        "handoff", to: paneID, coordinator: coordinator, write: { writes.append($0) })
    })
    let recovery = await coordinator.submitCommand(
      in: paneID, origin: .recovery(operationID: UUID()),
      paste: { writes.append("recovery draft") }, submit: { writes.append("return") })
    #expect(handoff == .rejectedDraftPresent)
    #expect(recovery == .interruptedWithDraft)
    #expect(writes == ["recovery draft"])
    #expect(coordinator.hasResidualDraft(in: paneID))
    let repeated = HandoffClient.deliverInstruction(
      "handoff", to: paneID, coordinator: coordinator, write: { writes.append($0) })
    #expect(repeated == .rejectedDraftPresent)
    #expect(writes == ["recovery draft"])
    #expect(HandoffClient.instructionFailureMessage(repeated)?.contains("draft remains") == true)
  }
}
