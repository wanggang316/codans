import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Reducer-level coverage for the Command Queue panel. The queue itself lives
/// on the catalog, so these tests assert on what the reducer writes through
/// `HierarchyClient` (and what it hands straight to `TerminalClient` for the
/// "send now" path) rather than on reducer state.
@MainActor
struct CommandQueueFeatureTests {
  private static let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

  /// Mutable stand-in for the catalog's per-pane queue, plus a log of
  /// everything written straight to the terminal.
  @MainActor
  final class Recorder {
    var queue: [QueuedCommand] = []
    var sent: [String] = []
  }

  private static func makeStore(
    paneID: PaneID,
    recorder: Recorder,
    configure: (inout CommandQueueFeature.State) -> Void = { _ in }
  ) -> TestStoreOf<CommandQueueFeature> {
    var state = CommandQueueFeature.State(paneID: paneID, now: epoch)
    configure(&state)
    return TestStore(initialState: state) {
      CommandQueueFeature()
    } withDependencies: {
      $0.date = .constant(epoch)
      $0[HierarchyClient.self].commandQueue = { _ in recorder.queue }
      $0[HierarchyClient.self].setCommandQueue = { _, queue in recorder.queue = queue }
      $0[TerminalClient.self].sendInput = { _, text in recorder.sent.append(text) }
    }
  }

  @Test
  func sendNowWritesToTheTerminalAndNeverQueues() async {
    let recorder = Recorder()
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder) { $0.mode = .now }
    await store.send(.draftChanged("ls -la")) { $0.draft = "ls -la" }
    await store.send(.submitted) { $0.draft = "" }

    #expect(recorder.sent == ["ls -la\n"])
    #expect(recorder.queue.isEmpty)
  }

  @Test
  func afterTaskModeAppendsAQueuedEntry() async {
    let recorder = Recorder()
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder)
    await store.send(.draftChanged("make test")) { $0.draft = "make test" }
    await store.send(.submitted) { $0.draft = "" }

    #expect(recorder.sent.isEmpty)
    #expect(recorder.queue.map(\.text) == ["make test"])
    #expect(recorder.queue.first?.timing == .afterCurrentTask)
  }

  @Test
  func scheduledModeCarriesTheRepeatInterval() async {
    let recorder = Recorder()
    let fireAt = Self.epoch.addingTimeInterval(3600)
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder) {
      $0.mode = .scheduled
      $0.scheduledAt = fireAt
      $0.repeatEnabled = true
      $0.repeatAmount = 30
      $0.repeatUnit = .minutes
    }
    await store.send(.draftChanged("/compact")) { $0.draft = "/compact" }
    await store.send(.submitted) { $0.draft = "" }

    #expect(recorder.queue.first?.timing == .scheduled(at: fireAt, repeatEvery: 1800))
  }

  @Test
  func repeatIsOmittedWhenTheToggleIsOff() async {
    let recorder = Recorder()
    let fireAt = Self.epoch.addingTimeInterval(3600)
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder) {
      $0.mode = .scheduled
      $0.scheduledAt = fireAt
      $0.repeatAmount = 30
    }
    await store.send(.draftChanged("/compact")) { $0.draft = "/compact" }
    await store.send(.submitted) { $0.draft = "" }

    #expect(recorder.queue.first?.timing == .scheduled(at: fireAt, repeatEvery: nil))
  }

  @Test
  func whitespaceOnlyDraftIsRejected() async {
    let recorder = Recorder()
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder)
    await store.send(.draftChanged("   \n ")) { $0.draft = "   \n " }
    await store.send(.submitted)

    #expect(recorder.queue.isEmpty)
    #expect(recorder.sent.isEmpty)
  }

  /// The panel reads the live catalog on every append, so an entry the runner
  /// drained between opening the panel and submitting is not resurrected.
  @Test
  func appendReadsTheLiveQueueRatherThanASnapshot() async {
    let recorder = Recorder()
    recorder.queue = [QueuedCommand(text: "already there", timing: .afterCurrentTask)]
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder)
    await store.send(.draftChanged("next")) { $0.draft = "next" }
    await store.send(.submitted) { $0.draft = "" }

    #expect(recorder.queue.map(\.text) == ["already there", "next"])
  }

  @Test
  func removeDropsOnlyTheTargetedEntry() async {
    let recorder = Recorder()
    let keep = QueuedCommand(text: "keep", timing: .afterCurrentTask)
    let drop = QueuedCommand(text: "drop", timing: .afterCurrentTask)
    recorder.queue = [keep, drop]
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder)

    await store.send(.removeTapped(drop.id))

    #expect(recorder.queue.map(\.text) == ["keep"])
  }

  @Test
  func clearAllEmptiesTheQueue() async {
    let recorder = Recorder()
    recorder.queue = [
      QueuedCommand(text: "a", timing: .afterCurrentTask),
      QueuedCommand(text: "b", timing: .afterCurrentTask),
    ]
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder)

    await store.send(.clearAllTapped)

    #expect(recorder.queue.isEmpty)
  }

  /// A panel left open long enough for its seeded time to go stale must not
  /// offer a schedule that is already in the past.
  @Test
  func switchingToScheduleReseedsAPastDate() async {
    let recorder = Recorder()
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder) {
      $0.scheduledAt = Self.epoch.addingTimeInterval(-3600)
    }
    let expected = CommandQueueFeature.State.defaultScheduleDate(from: Self.epoch)

    await store.send(.modeChanged(.scheduled)) {
      $0.mode = .scheduled
      $0.scheduledAt = expected
    }
    #expect(expected > Self.epoch)
  }

  @Test
  func repeatAmountIsClampedToAPositiveValue() async {
    let recorder = Recorder()
    let store = Self.makeStore(paneID: PaneID(), recorder: recorder)
    await store.send(.repeatAmountChanged(0)) { $0.repeatAmount = 1 }
  }
}
