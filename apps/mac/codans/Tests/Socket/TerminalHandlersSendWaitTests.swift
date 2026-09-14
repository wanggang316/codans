import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

/// `terminal.sendInput` with `wait`: the pane's busy bit and a still screen
/// decide completion; `capture` returns the lines the command added.
@MainActor
struct TerminalHandlersSendWaitTests {
  /// Busy answers in order, clamping to the last.
  private final class BusyScript {
    var answers: [Bool]
    private var cursor = 0
    init(_ answers: [Bool]) { self.answers = answers }
    func next() -> Bool {
      defer { cursor += 1 }
      return cursor < answers.count ? answers[cursor] : answers.last ?? false
    }
  }

  private func makeHandlers(
    sink: FakeSink, clock: StabilityClock, busy: BusyScript
  ) -> TerminalHandlers {
    let manager = HierarchyManager(
      catalog: Catalog(),
      store: CatalogStore(
        fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("codans-send-wait-\(UUID().uuidString).json")),
      runtime: FakeHierarchyRuntime()
    )
    return TerminalHandlers(
      sink: sink, catalog: { manager.catalog }, clock: clock, paneIsBusy: { _ in busy.next() })
  }

  private func send(
    _ handlers: TerminalHandlers, pane: PaneID, text: String, wait: TerminalHandlers.SendWaitParams,
    capture: Bool
  ) async throws -> TerminalHandlers.SendInputResult {
    let params = try JSONValue.encoded(
      TerminalHandlers.SendInputParams(paneID: pane, text: text, wait: wait, capture: capture))
    let outcome = await handlers.sendInput(params)
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: TerminalHandlers.SendInputResult.self)
  }

  @Test
  func completesOnceTheCommandIsNoLongerBusyAndTheScreenSettles() async throws {
    let sink = FakeSink()
    let clock = TerminalStabilityWaiterTests.VirtualClock()
    let pane = PaneID()
    sink.registered.insert(pane.raw)
    // before-read, then the loop: the command echoes, prints, redraws the prompt.
    sink.textScript[pane.raw] = ["$ ", "$ ", "$ echo hi\nhi\n$ ", "$ echo hi\nhi\n$ "]
    let busy = BusyScript([true, true, false])
    let handlers = makeHandlers(sink: sink, clock: clock, busy: busy)

    let result = try await send(
      handlers, pane: pane, text: "echo hi\n",
      wait: .init(timeoutMillis: 5000, stableMillis: 150, graceMillis: 1500), capture: true)

    #expect(result.delivered)
    #expect(result.completed == true)
    #expect(result.busyObserved == true)
    #expect(result.output == "hi")
    #expect((result.waitedMillis ?? 0) >= 150)
  }

  @Test
  func aCommandTooQuickForTheBusyPollerCompletesAfterTheGrace() async throws {
    let sink = FakeSink()
    let clock = TerminalStabilityWaiterTests.VirtualClock()
    let pane = PaneID()
    sink.registered.insert(pane.raw)
    sink.textScript[pane.raw] = ["$ ", "$ true\n$ "]
    let handlers = makeHandlers(sink: sink, clock: clock, busy: BusyScript([false]))

    let result = try await send(
      handlers, pane: pane, text: "true\n",
      wait: .init(timeoutMillis: 5000, stableMillis: 100, graceMillis: 800), capture: false)

    #expect(result.completed == true)
    #expect(result.busyObserved == false)
    #expect((result.waitedMillis ?? 0) >= 800)
    #expect(result.output == nil)
  }

  @Test
  func aCommandStillBusyAtTheDeadlineReportsIncomplete() async throws {
    let sink = FakeSink()
    let clock = TerminalStabilityWaiterTests.VirtualClock()
    let pane = PaneID()
    sink.registered.insert(pane.raw)
    sink.textScript[pane.raw] = ["$ ", "$ sleep 9\n"]
    let handlers = makeHandlers(sink: sink, clock: clock, busy: BusyScript([true]))

    let result = try await send(
      handlers, pane: pane, text: "sleep 9\n",
      wait: .init(timeoutMillis: 700, stableMillis: 100, graceMillis: 300), capture: false)

    #expect(result.completed == false)
    #expect(result.busyObserved == true)
    #expect((result.waitedMillis ?? 0) >= 700)
  }

  @Test
  func capturedOutputDropsTheEchoAndTheRedrawnPrompt() {
    let before = "old line\nrepo on main\n❯ "
    let after = "old line\nrepo on main\n❯ git status --short\n M a.swift\n?? b.swift\nrepo on main\n❯ \n\n"
    let output = TerminalHandlers.capturedOutput(before: before, after: after, sent: "git status --short\n")
    #expect(output == " M a.swift\n?? b.swift\nrepo on main")

    // A cleared screen has no common prefix: everything after the echo comes back.
    let cleared = TerminalHandlers.capturedOutput(before: "x\ny\n$ ", after: "$ ls\na\nb\n$ ", sent: "ls")
    #expect(cleared == "a\nb")
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
