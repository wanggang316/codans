import Foundation
import Testing

@testable import CodansCore

/// Policy + arithmetic for the per-Pane command queue. Everything here is
/// pure: the runner that drives it lives in the app target and is tested
/// separately against these primitives.
struct CommandQueueTests {
  private let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

  // MARK: - Schedule arithmetic

  @Test
  func oneShotScheduleIsSpentAfterFiring() {
    let timing = QueuedCommandTiming.scheduled(at: epoch, repeatEvery: nil)
    #expect(timing.advanced(firedAt: epoch) == nil)
  }

  @Test
  func repeatingScheduleAdvancesOnePeriod() {
    let timing = QueuedCommandTiming.scheduled(at: epoch, repeatEvery: 60)
    #expect(
      timing.advanced(firedAt: epoch)
        == .scheduled(at: epoch.addingTimeInterval(60), repeatEvery: 60)
    )
  }

  /// The relaunch case: the app was closed across many periods. The due tick
  /// fires once and the schedule lands on the next *future* occurrence rather
  /// than replaying every period that elapsed while the app was down.
  @Test
  func repeatingScheduleSkipsPeriodsMissedWhileClosed() {
    let timing = QueuedCommandTiming.scheduled(at: epoch, repeatEvery: 60)
    let muchLater = epoch.addingTimeInterval(605)
    let next = timing.advanced(firedAt: muchLater)
    #expect(next == .scheduled(at: epoch.addingTimeInterval(660), repeatEvery: 60))
  }

  @Test
  func nextOccurrenceIsStrictlyAfterTheReferencePoint() {
    // Firing exactly on an occurrence must move to the following one, not
    // return the same instant and re-fire on the next tick.
    let onTheDot = epoch.addingTimeInterval(120)
    let next = QueuedCommandTiming.nextOccurrence(from: epoch, every: 60, after: onTheDot)
    #expect(next == epoch.addingTimeInterval(180))
  }

  @Test
  func scheduleInTheFutureKeepsItsOriginalDate() {
    let start = epoch.addingTimeInterval(500)
    #expect(QueuedCommandTiming.nextOccurrence(from: start, every: 60, after: epoch) == start)
  }

  @Test
  func afterCurrentTaskLeavesTheQueueOnceFired() {
    #expect(QueuedCommandTiming.afterCurrentTask.advanced(firedAt: epoch) == nil)
  }

  @Test
  func zeroIntervalIsTreatedAsOneShot() {
    let timing = QueuedCommandTiming.scheduled(at: epoch, repeatEvery: 0)
    #expect(timing.isRepeating == false)
    #expect(timing.advanced(firedAt: epoch) == nil)
  }

  // MARK: - Selection policy

  @Test
  func queuedEntryWaitsForReadiness() {
    let queue = [QueuedCommand(text: "make test", timing: .afterCurrentTask)]
    #expect(queue.nextToFire(now: epoch, isReady: false) == nil)
    #expect(queue.nextToFire(now: epoch, isReady: true)?.text == "make test")
  }

  @Test
  func onlyTheHeadOfTheQueueFires() {
    let queue = [
      QueuedCommand(text: "first", timing: .afterCurrentTask),
      QueuedCommand(text: "second", timing: .afterCurrentTask),
    ]
    #expect(queue.nextToFire(now: epoch, isReady: true)?.text == "first")
  }

  @Test
  func scheduledEntryFiresRegardlessOfReadiness() {
    // A wall-clock time the user picked must not be silently postponed
    // because the pane happens to be busy.
    let queue = [QueuedCommand(text: "/compact", timing: .scheduled(at: epoch, repeatEvery: nil))]
    #expect(queue.nextToFire(now: epoch, isReady: false)?.text == "/compact")
  }

  @Test
  func scheduledEntryDoesNotFireBeforeItsTime() {
    let queue = [
      QueuedCommand(text: "/compact", timing: .scheduled(at: epoch.addingTimeInterval(60), repeatEvery: nil))
    ]
    #expect(queue.nextToFire(now: epoch, isReady: true) == nil)
  }

  @Test
  func dueScheduleWinsOverAReadyQueuedEntry() {
    let queued = QueuedCommand(text: "queued", timing: .afterCurrentTask)
    let due = QueuedCommand(text: "due", timing: .scheduled(at: epoch, repeatEvery: nil))
    #expect([queued, due].nextToFire(now: epoch, isReady: true)?.text == "due")
  }

  @Test
  func earliestDueScheduleWinsAmongOverdueEntries() {
    let late = QueuedCommand(text: "late", timing: .scheduled(at: epoch.addingTimeInterval(-10), repeatEvery: nil))
    let earlier = QueuedCommand(
      text: "earlier", timing: .scheduled(at: epoch.addingTimeInterval(-60), repeatEvery: nil))
    #expect([late, earlier].nextToFire(now: epoch, isReady: true)?.text == "earlier")
  }

  // MARK: - Advancing the queue

  @Test
  func firingAOneShotRemovesItAndKeepsTheRest() {
    let first = QueuedCommand(text: "first", timing: .afterCurrentTask)
    let second = QueuedCommand(text: "second", timing: .afterCurrentTask)
    let advanced = [first, second].advancing(first, firedAt: epoch)
    #expect(advanced.map(\.text) == ["second"])
  }

  @Test
  func firingARepeatKeepsItInPlaceWithANewDate() {
    let repeating = QueuedCommand(text: "/compact", timing: .scheduled(at: epoch, repeatEvery: 60))
    let tail = QueuedCommand(text: "after", timing: .afterCurrentTask)
    let advanced = [repeating, tail].advancing(repeating, firedAt: epoch)
    #expect(advanced.map(\.text) == ["/compact", "after"])
    #expect(advanced[0].timing == .scheduled(at: epoch.addingTimeInterval(60), repeatEvery: 60))
    #expect(advanced[0].id == repeating.id)
  }

  // MARK: - Persistence

  @Test
  func timingRoundTripsThroughJSON() throws {
    let cases: [QueuedCommandTiming] = [
      .afterCurrentTask,
      .scheduled(at: epoch, repeatEvery: nil),
      .scheduled(at: epoch, repeatEvery: 1800),
    ]
    for timing in cases {
      let data = try JSONEncoder().encode(QueuedCommand(text: "cmd", timing: timing))
      let decoded = try JSONDecoder().decode(QueuedCommand.self, from: data)
      #expect(decoded.timing == timing)
    }
  }

  @Test
  func terminalContentOmitsAnEmptyQueueFromItsEncodedForm() throws {
    let state = TerminalContentState(workingDirectory: "/tmp")
    let json =
      try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(state)
      ) as? [String: Any]
    #expect(json?["commandQueue"] == nil)
  }

  @Test
  func terminalContentRoundTripsANonEmptyQueue() throws {
    let state = TerminalContentState(
      workingDirectory: "/tmp",
      commandQueue: [
        QueuedCommand(text: "make test", timing: .afterCurrentTask),
        QueuedCommand(text: "/compact", timing: .scheduled(at: epoch, repeatEvery: 900)),
      ]
    )
    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: try JSONEncoder().encode(state))
    #expect(decoded.commandQueue == state.commandQueue)
  }

  /// A queue written by a build that knows a timing kind this one doesn't
  /// must cost the queue, not the Tab.
  @Test
  func terminalContentSurvivesAnUndecodableQueue() throws {
    let json = """
      {
        "workingDirectory": "/tmp",
        "commandQueue": [{ "id": "\(UUID().uuidString)", "text": "x",
                           "createdAt": 0, "timing": { "kind": "fromTheFuture" } }]
      }
      """
    let decoded = try JSONDecoder().decode(TerminalContentState.self, from: Data(json.utf8))
    #expect(decoded.commandQueue.isEmpty)
    #expect(decoded.workingDirectory == "/tmp")
  }

  // MARK: - What a close would discard

  @Test
  func countsQueuedCommandsThroughTheHierarchy() throws {
    let queued = Tab(
      content: .terminal(
        workingDirectory: "/tmp/w",
        commandQueue: [
          QueuedCommand(text: "a", timing: .afterCurrentTask),
          QueuedCommand(text: "b", timing: .afterCurrentTask)
        ]))
    let idle = Tab(content: .terminal(workingDirectory: "/tmp/w"))
    let busyPane = Pane(tabs: [queued, idle])
    let idlePane = Pane(tabs: [idle])
    let tree = try SplitTree(leaf: busyPane.id).inserting(idlePane.id, at: busyPane.id, direction: .right)
    var archived = Worktree(
      name: "old", path: "/tmp/old", branch: "old", splitTree: SplitTree(leaf: busyPane.id), panes: [busyPane],
      focusedPaneID: busyPane.id)
    archived.archived = true
    let live = Worktree(
      name: "w", path: "/tmp/w", branch: "main", splitTree: tree, panes: [busyPane, idlePane],
      focusedPaneID: busyPane.id)
    let project = Project(name: "p", rootPath: "/tmp", worktrees: [live, archived])

    #expect(queued.queuedCommandCount == 2)
    #expect(idle.queuedCommandCount == 0)
    #expect(busyPane.queuedCommandCount == 2)
    #expect(idlePane.queuedCommandCount == 0)
    #expect(live.queuedCommandCount == 2)
    // Removing the project takes the archived worktree's dormant queue too.
    #expect(project.queuedCommandCount == 4)
  }
}
