import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// `terminal.sendEvents` applies a batch in order and reports each event it
/// could not deliver by index, without failing the events around it.
@MainActor
struct TerminalHandlersSendEventsTests {
  private let sink = FakeSink()
  private let clock = TerminalStabilityWaiterTests.VirtualClock()
  private let pane = Pane(workingDirectory: "/repo")

  private func makeHandlers(sink: FakeSink?) -> TerminalHandlers {
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let worktree = Worktree(name: "main", path: "/repo", branch: "main", tabs: [tab])
    let catalog = Catalog(projects: [Project(name: "repo", rootPath: "/repo", worktrees: [worktree])])
    return TerminalHandlers(sink: sink, catalog: { catalog }, clock: clock)
  }

  private func send(
    _ events: [IPC.TerminalInputEvent], to paneID: PaneID? = nil, sink: FakeSink?
  ) async throws -> RouterOutcome {
    await makeHandlers(sink: sink).sendEvents(
      try JSONValue.encoded(IPC.TerminalSendEventsRequest(paneID: paneID ?? pane.id, events: events)))
  }

  private func result(_ outcome: RouterOutcome) throws -> IPC.TerminalSendEventsResult {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: IPC.TerminalSendEventsResult.self)
  }

  @Test
  func deliversEveryKindInOrderAndWaitsOnDelays() async throws {
    sink.registered.insert(pane.id.raw)
    let events: [IPC.TerminalInputEvent] = [
      .paste("git status"),
      .delay(millis: 30),
      .key(code: "Enter", text: nil, mods: .none),
      .text("你好"),
    ]
    let outcome = try result(await send(events, sink: sink))
    #expect(outcome.delivered == 4)
    #expect(outcome.rejected.isEmpty)
    #expect(sink.inputEvents == [events[0], events[2], events[3]])
    #expect(clock.nowMillis() == 30)
  }

  @Test
  func rejectsOnlyTheEventsThatCannotLand() async throws {
    sink.registered.insert(pane.id.raw)
    sink.bindingCodes = ["KeyW"]
    let oversized = String(repeating: "x", count: IPC.TerminalInputEvent.maxTextBytes + 1)
    let events: [IPC.TerminalInputEvent] = [
      .key(code: "KeyW", text: nil, mods: IPC.TerminalKeyModifiers(super: true)),
      .unknown(kind: "gesture"),
      .paste(oversized),
      .delay(millis: IPC.TerminalInputEvent.maxDelayMillis + 1),
      .delay(millis: -1),
      .text("ok"),
    ]
    let outcome = try result(await send(events, sink: sink))
    #expect(outcome.delivered == 1)
    #expect(
      outcome.rejected == [
        IPC.TerminalInputRejection(index: 0, reason: "binding"),
        IPC.TerminalInputRejection(index: 1, reason: "unknownEvent"),
        IPC.TerminalInputRejection(index: 2, reason: "tooLarge"),
        IPC.TerminalInputRejection(index: 3, reason: "outOfRange"),
        IPC.TerminalInputRejection(index: 4, reason: "outOfRange"),
      ])
    #expect(sink.inputEvents == [.text("ok")])
    #expect(clock.nowMillis() == 0)
  }

  @Test
  func delaysShareOneBudgetPerCall() async throws {
    sink.registered.insert(pane.id.raw)
    let events = Array(repeating: IPC.TerminalInputEvent.delay(millis: 500), count: 5)
    let outcome = try result(await send(events, sink: sink))
    #expect(outcome.delivered == 4)
    #expect(outcome.rejected == [IPC.TerminalInputRejection(index: 4, reason: "outOfRange")])
    #expect(clock.nowMillis() == IPC.TerminalSendEventsRequest.maxTotalDelayMillis)
  }

  @Test
  func aSurfaceThatClosesMidBatchRejectsTheRest() async throws {
    sink.registered.insert(pane.id.raw)
    sink.closesAfter = 1
    let outcome = try result(
      await send([.text("a"), .text("b"), .delay(millis: 10), .text("c")], sink: sink))
    #expect(outcome.delivered == 1)
    #expect(outcome.rejected.map(\.index) == [1, 2, 3])
    #expect(outcome.rejected.allSatisfy { $0.reason == "paneGone" })
    #expect(clock.nowMillis() == 0)
  }

  @Test
  func aPaneNotOpenOnTheMacIsUnsupported() async throws {
    sink.registered.insert(pane.id.raw)
    sink.notLive.insert(pane.id.raw)
    let outcome = try await send([.text("a")], sink: sink)
    guard case .failed(.unsupported(let reason)) = outcome else {
      Issue.record("expected .unsupported, got \(outcome)")
      return
    }
    #expect(reason == "pane not open on the Mac")
    #expect(sink.inputEvents.isEmpty)
  }

  @Test
  func anUnknownPaneIsNotFoundAndNoSinkIsUnsupported() async throws {
    let missing = try await send([.text("a")], to: PaneID(), sink: sink)
    guard case .failed(.notFound(let kind, _)) = missing else {
      Issue.record("expected .notFound, got \(missing)")
      return
    }
    #expect(kind == "pane")

    let unbound = try await send([.text("a")], sink: nil)
    guard case .failed(.unsupported) = unbound else {
      Issue.record("expected .unsupported, got \(unbound)")
      return
    }
  }

  @Test
  func anOversizedBatchIsInvalid() async throws {
    sink.registered.insert(pane.id.raw)
    let events = Array(
      repeating: IPC.TerminalInputEvent.text("a"), count: IPC.TerminalSendEventsRequest.maxEvents + 1)
    let outcome = try await send(events, sink: sink)
    guard case .failed(.invalidParams) = outcome else {
      Issue.record("expected .invalidParams, got \(outcome)")
      return
    }
    #expect(sink.inputEvents.isEmpty)
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
