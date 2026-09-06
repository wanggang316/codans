import CodansCore
import Foundation
import Testing

@testable import Codans

/// Drain-pass behaviour. The runner's poll loop is not exercised here — every
/// test drives `drain()` directly against a scripted clock so the assertions
/// are about firing policy, not about timer cadence.
@MainActor
struct CommandQueueRunnerTests {
  /// Scriptable seams standing in for the catalog, the agent registry, and
  /// the terminal surface.
  @MainActor
  final class Harness {
    var queues: [PaneID: [QueuedCommand]] = [:]
    var ready: Set<PaneID> = []
    var live: Set<PaneID> = []
    var sent: [(paneID: PaneID, text: String)] = []
    var now: Date

    let paneID = PaneID()
    let otherPaneID = PaneID()

    init(now: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)) {
      self.now = now
    }

    func makeRunner() -> CommandQueueRunner {
      CommandQueueRunner(
        queuedPanes: { [self] in
          queues.filter { !$0.value.isEmpty }.map { (paneID: $0.key, queue: $0.value) }
        },
        setQueue: { [self] paneID, queue in queues[paneID] = queue },
        isPaneReady: { [self] paneID in ready.contains(paneID) },
        hasLiveSurface: { [self] paneID in live.contains(paneID) },
        send: { [self] paneID, text in sent.append((paneID, text)) },
        now: { [self] in now }
      )
    }
  }

  @Test
  func readyPaneFiresItsQueuedCommand() {
    let h = Harness()
    h.live = [h.paneID]
    h.ready = [h.paneID]
    h.queues[h.paneID] = [QueuedCommand(text: "make test", timing: .afterCurrentTask)]

    h.makeRunner().drain()

    #expect(h.sent.count == 1)
    #expect(h.sent.first?.paneID == h.paneID)
    // No trailing newline: submission is a separate Return keypress issued
    // by `TerminalClient.sendCommand`, so an agent TUI can't read the
    // command and its newline as one pasted block.
    #expect(h.sent.first?.text == "make test")
    #expect(h.queues[h.paneID]?.isEmpty == true)
  }

  @Test
  func busyPaneHoldsItsQueuedCommand() {
    let h = Harness()
    h.live = [h.paneID]
    h.queues[h.paneID] = [QueuedCommand(text: "make test", timing: .afterCurrentTask)]

    h.makeRunner().drain()

    #expect(h.sent.isEmpty)
    #expect(h.queues[h.paneID]?.count == 1)
  }

  /// A pane whose surface has not been created yet would swallow the send.
  /// The entry must survive until the pane materialises.
  @Test
  func paneWithoutASurfaceKeepsItsQueue() {
    let h = Harness()
    h.ready = [h.paneID]
    h.queues[h.paneID] = [QueuedCommand(text: "make test", timing: .afterCurrentTask)]

    h.makeRunner().drain()

    #expect(h.sent.isEmpty)
    #expect(h.queues[h.paneID]?.count == 1)
  }

  /// The settle window: readiness is derived from rendered terminal state and
  /// lags the keystroke that starts the work, so a second command must not
  /// follow on the very next pass.
  @Test
  func consecutiveQueuedCommandsAreSeparatedByTheSettleWindow() {
    let h = Harness()
    h.live = [h.paneID]
    h.ready = [h.paneID]
    h.queues[h.paneID] = [
      QueuedCommand(text: "first", timing: .afterCurrentTask),
      QueuedCommand(text: "second", timing: .afterCurrentTask),
    ]
    let runner = h.makeRunner()

    runner.drain()
    h.now = h.now.addingTimeInterval(0.5)
    runner.drain()
    #expect(h.sent.map(\.text) == ["first"])

    h.now = h.now.addingTimeInterval(CommandQueueRunner.settleWindow)
    runner.drain()
    #expect(h.sent.map(\.text) == ["first", "second"])
  }

  @Test
  func dueScheduleFiresEvenWhileThePaneIsBusy() {
    let h = Harness()
    h.live = [h.paneID]
    h.queues[h.paneID] = [
      QueuedCommand(text: "/compact", timing: .scheduled(at: h.now, repeatEvery: nil))
    ]

    h.makeRunner().drain()

    #expect(h.sent.map(\.text) == ["/compact"])
    #expect(h.queues[h.paneID]?.isEmpty == true)
  }

  @Test
  func futureScheduleIsNotFired() {
    let h = Harness()
    h.live = [h.paneID]
    h.ready = [h.paneID]
    h.queues[h.paneID] = [
      QueuedCommand(
        text: "/compact",
        timing: .scheduled(at: h.now.addingTimeInterval(60), repeatEvery: nil)
      )
    ]

    h.makeRunner().drain()

    #expect(h.sent.isEmpty)
  }

  @Test
  func repeatingScheduleStaysQueuedAndRearms() {
    let h = Harness()
    h.live = [h.paneID]
    h.queues[h.paneID] = [
      QueuedCommand(text: "/compact", timing: .scheduled(at: h.now, repeatEvery: 60))
    ]
    let runner = h.makeRunner()

    runner.drain()
    #expect(h.queues[h.paneID]?.count == 1)
    #expect(h.queues[h.paneID]?.first?.timing == .scheduled(at: h.now.addingTimeInterval(60), repeatEvery: 60))

    // Next period. Past the settle window, so nothing throttles it.
    h.now = h.now.addingTimeInterval(60)
    runner.drain()
    #expect(h.sent.map(\.text) == ["/compact", "/compact"])
  }

  @Test
  func panesDrainIndependently() {
    let h = Harness()
    h.live = [h.paneID, h.otherPaneID]
    h.ready = [h.paneID, h.otherPaneID]
    h.queues[h.paneID] = [QueuedCommand(text: "a", timing: .afterCurrentTask)]
    h.queues[h.otherPaneID] = [QueuedCommand(text: "b", timing: .afterCurrentTask)]

    h.makeRunner().drain()

    #expect(Set(h.sent.map(\.text)) == ["a", "b"])
  }

  // MARK: - Readiness predicate

  /// Coding agents emit terminal progress sequences throughout a task, so the
  /// raw busy union never goes quiet for a working agent. An agent-bound pane
  /// must be judged by the agent state machine alone.
  @Test
  func agentPaneIgnoresRawTerminalBusy() {
    #expect(CommandQueueRunner.isReady(agentState: .idle, terminalBusy: true))
    #expect(CommandQueueRunner.isReady(agentState: .finished, terminalBusy: true))
    #expect(!CommandQueueRunner.isReady(agentState: .working, terminalBusy: false))
  }

  /// `blocked` means the agent is waiting on an answer to a specific
  /// question — a queued prompt typed there would be eaten as that answer.
  @Test
  func blockedAgentIsNotReady() {
    #expect(!CommandQueueRunner.isReady(agentState: .blocked, terminalBusy: false))
  }

  @Test
  func plainPaneFallsBackToTerminalBusy() {
    #expect(CommandQueueRunner.isReady(agentState: nil, terminalBusy: false))
    #expect(!CommandQueueRunner.isReady(agentState: nil, terminalBusy: true))
  }
}
