import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct TerminalEngineTests {
  private final class MutableClock: @unchecked Sendable {
    private(set) var now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(by seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
    }
  }

  private final class TempFile {
    let url: URL
    init() {
      self.url = FileManager.default.temporaryDirectory
        .appending(component: UUID().uuidString + ".json")
    }
    deinit {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func makeEngine(
    clock: MutableClock = MutableClock()
  ) -> (TerminalEngine, HierarchyManager, MutableClock, TempFile) {
    let temp = TempFile()
    let fakeRuntime = FakeHierarchyRuntime()
    let store = CatalogStore(fileURL: temp.url)
    let manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
    let engine = TerminalEngine(store: store, hierarchy: manager) { clock.now }
    return (engine, manager, clock, temp)
  }

  // MARK: - Program status

  @Test
  func programStatusPublishesOnlyChangedSummaries() async {
    let (engine, _, _, _) = makeEngine()
    let contentID = ContentID()
    let stream = engine.events()
    let working = ProgramStatusReport(state: .working, app: "claude-code")
    engine.ingestProgramStatus(working, for: contentID)
    engine.ingestProgramStatus(working, for: contentID)
    engine.ingestProgramStatus(ProgramStatusReport(state: .clear), for: contentID)
    engine.finishEventStream()

    var summaries: [ProgramStatusSummary?] = []
    for await event in stream {
      if case .paneProgramStatusChanged(let id, let summary) = event, id == contentID {
        summaries.append(summary)
      }
    }
    #expect(summaries.count == 2)
    #expect(summaries.first??.root?.state == .working)
    #expect(summaries.last! == nil)
  }

  @Test
  func programStatusOfAnUnboundPaneGovernsNothing() {
    let (engine, _, _, _) = makeEngine()
    let contentID = ContentID()
    engine.ingestProgramStatus(ProgramStatusReport(state: .working, app: "claude-code"), for: contentID)
    #expect(!engine.programStatusGoverns(contentID))
  }

  // MARK: - Fan-out

  @Test
  func subscribeThenEmitDeliversInOrder() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()
    let contentID = ContentID()

    // Register the continuation synchronously by calling events() first —
    // the AsyncStream initializer closure registers with the engine during
    // this call, so subsequent emits reach the buffer even before the
    // async iterator runs.
    let stream = engine.events()
    engine.emit(.paneCreated(contentID, tabID))
    engine.emit(.paneReady(contentID))

    var iterator = stream.makeAsyncIterator()
    guard case .paneCreated(let pid1, let tid1) = await iterator.next() else {
      Issue.record("expected paneCreated")
      return
    }
    #expect(pid1 == contentID && tid1 == tabID)
    guard case .paneReady(let pid2) = await iterator.next() else {
      Issue.record("expected paneReady")
      return
    }
    #expect(pid2 == contentID)
  }

  @Test
  func multipleSubscribersEachReceiveAllEvents() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()

    let streamA = engine.events()
    let streamB = engine.events()

    engine.emit(.tabActivated(tabID))
    engine.emit(.tabActivated(tabID))
    engine.emit(.tabActivated(tabID))

    var iterA = streamA.makeAsyncIterator()
    var iterB = streamB.makeAsyncIterator()
    var countA = 0
    var countB = 0
    for _ in 0..<3 {
      _ = await iterA.next()
      countA += 1
      _ = await iterB.next()
      countB += 1
    }
    #expect(countA == 3)
    #expect(countB == 3)
  }

  @Test
  func lifecycleOnlySubscriberSkipsOutputEvents() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()
    let contentID = ContentID()

    let stream = engine.events(lifecycleOnly: true)
    engine.emit(.paneOutput(contentID, Data([0x01])))
    engine.emit(.paneOutput(contentID, Data([0x02])))
    engine.emit(.tabActivated(tabID))
    engine.emit(.paneReady(contentID))

    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    let second = await iterator.next()

    for event in [first, second].compactMap({ $0 }) {
      switch event {
      case .paneOutput, .paneViewportChanged, .paneIdle, .foregroundJobChanged:
        Issue.record("output event leaked to lifecycle-only subscriber")
      default:
        break
      }
    }
  }

  // MARK: - Output coalescing

  @Test
  func appendOutputCoalescesIntoSingleEvent() async throws {
    let (engine, _, _, _) = makeEngine()
    let contentID = ContentID()
    let stream = engine.events()

    engine.appendOutput(contentID: contentID, bytes: Data([0x01, 0x02]))
    engine.appendOutput(contentID: contentID, bytes: Data([0x03]))
    engine.flushOutput(for: contentID)

    var iterator = stream.makeAsyncIterator()
    guard case .paneOutput(let pid, let data) = await iterator.next() else {
      Issue.record("expected paneOutput")
      return
    }
    #expect(pid == contentID)
    #expect(data == Data([0x01, 0x02, 0x03]))
  }

  @Test
  func disposeOutputBufferFlushesPendingBytes() async throws {
    let (engine, _, _, _) = makeEngine()
    let contentID = ContentID()
    let stream = engine.events()

    engine.appendOutput(contentID: contentID, bytes: Data([0xAA]))
    engine.disposeOutputBuffer(for: contentID)

    var iterator = stream.makeAsyncIterator()
    if case .paneOutput(_, let data) = await iterator.next() {
      #expect(data == Data([0xAA]))
    } else {
      Issue.record("expected paneOutput")
    }
  }

  // MARK: - Teardown

  @Test
  func finishEventStreamIsIdempotentAndSilencesEmit() async {
    let (engine, _, _, _) = makeEngine()
    let tabID = TabID()
    let stream = engine.events()

    engine.emit(.tabActivated(tabID))
    engine.finishEventStream()
    // Post-finish emits are silent no-ops.
    engine.emit(.tabActivated(tabID))
    engine.finishEventStream()  // second call safe.

    var count = 0
    for await _ in stream { count += 1 }
    #expect(count == 1)
  }

  // MARK: - Crash isolation

  // MARK: - Crash isolation helpers

  private func seedPane(
    in manager: HierarchyManager
  ) async throws -> (ProjectID, WorktreeID, TabID, ContentID) {
    let projectID = manager.addProject(name: "p", rootPath: "/", gitRoot: "/")
    let worktreeID = try manager.createWorktree(in: projectID, name: "w", path: "/w", branch: "main")
    let address = try manager.newTab(
      in: nil, worktreeID: worktreeID, projectID: projectID, content: .terminal(workingDirectory: "/w"))
    try await manager.ensureSurface(for: address.contentID)
    return (projectID, worktreeID, address.tabID, address.contentID)
  }

  // MARK: - Crash isolation

  @Test
  func firstCrashSurvives() async throws {
    let (engine, manager, _, _) = makeEngine()
    let (_, _, tabID, contentID) = try await seedPane(in: manager)

    let outcome = engine.recordPaneCrash(contentID: contentID, reason: "segv")
    #expect(outcome == .survived)
    #expect(manager.catalog.projects[0].worktrees[0].allTabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func threeCrashesWithinWindowAutoClosesTabAndEmitsCrashLoopCause() async throws {
    let (engine, manager, clk, _) = makeEngine()
    let (_, _, tabID, contentID) = try await seedPane(in: manager)

    let stream = engine.events(lifecycleOnly: true)

    #expect(engine.recordPaneCrash(contentID: contentID, reason: "1") == .survived)
    clk.advance(by: 5)
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "2") == .survived)
    clk.advance(by: 5)
    let outcome = engine.recordPaneCrash(contentID: contentID, reason: "3")
    #expect(outcome == .tabAutoClosed(tabID))
    #expect(manager.catalog.projects[0].worktrees[0].allTabs.isEmpty)

    var events: [TerminalEvent] = []
    var iterator = stream.makeAsyncIterator()
    while let event = await iterator.next() {
      events.append(event)
      if case .tabAutoClosed = event { break }
    }

    guard case .tabAutoClosed(let closedTabID, let cause) = events.last else {
      Issue.record("expected last event to be tabAutoClosed; got \(String(describing: events.last))")
      return
    }
    #expect(closedTabID == tabID)
    #expect(cause == .crashLoop(count: 3, window: 30))
    let crashCount = events.reduce(into: 0) { count, event in
      if case .paneCrashed = event { count += 1 }
    }
    #expect(crashCount == 3)
  }

  @Test
  func crashesOlderThanWindowDropFromRing() async throws {
    let (engine, manager, clk, _) = makeEngine()
    let (_, _, tabID, contentID) = try await seedPane(in: manager)

    #expect(engine.recordPaneCrash(contentID: contentID, reason: "1") == .survived)
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "2") == .survived)
    clk.advance(by: 31)
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "3") == .survived)
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "4") == .survived)
    #expect(manager.catalog.projects[0].worktrees[0].allTabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func crashExactlyAtWindowBoundaryIsStillCounted() async throws {
    let (engine, manager, clk, _) = makeEngine()
    let (_, _, tabID, contentID) = try await seedPane(in: manager)

    // t=0
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "1") == .survived)
    // advance to exactly window boundary (30s). Older entry should still be
    // included (>= cutoff, not > cutoff).
    clk.advance(by: 30)
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "2") == .survived)
    let outcome = engine.recordPaneCrash(contentID: contentID, reason: "3")
    #expect(outcome == .tabAutoClosed(tabID))
  }

  @Test
  func retryPaneClearsRingAndEmitsReady() async throws {
    let (engine, manager, _, _) = makeEngine()
    let (_, _, tabID, contentID) = try await seedPane(in: manager)

    _ = engine.recordPaneCrash(contentID: contentID, reason: "1")
    _ = engine.recordPaneCrash(contentID: contentID, reason: "2")
    #expect(engine.retryPane(contentID))

    #expect(engine.recordPaneCrash(contentID: contentID, reason: "3") == .survived)
    #expect(engine.recordPaneCrash(contentID: contentID, reason: "4") == .survived)
    #expect(manager.catalog.projects[0].worktrees[0].allTabs.contains(where: { $0.id == tabID }))
  }

  @Test
  func retryPaneReturnsFalseForUnknownID() {
    let (engine, _, _, _) = makeEngine()
    #expect(!engine.retryPane(ContentID()))
  }

  @Test
  func tabAutoCloseLeavesTheSiblingTabOfThePaneAlone() async throws {
    let (engine, manager, clk, _) = makeEngine()
    let (projectID, worktreeID, tabID, contentA) = try await seedPane(in: manager)
    let sibling = try manager.newTab(
      in: nil, worktreeID: worktreeID, projectID: projectID, content: .terminal(workingDirectory: "/w"))
    try await manager.ensureSurface(for: sibling.contentID)

    let stream = engine.events(lifecycleOnly: true)

    _ = engine.recordPaneCrash(contentID: contentA, reason: "1")
    clk.advance(by: 5)
    _ = engine.recordPaneCrash(contentID: contentA, reason: "2")
    clk.advance(by: 5)
    #expect(engine.recordPaneCrash(contentID: contentA, reason: "3") == .tabAutoClosed(tabID))

    var events: [TerminalEvent] = []
    var iterator = stream.makeAsyncIterator()
    while let event = await iterator.next() {
      events.append(event)
      if case .tabAutoClosed = event { break }
    }

    // A Tab holds exactly one Content, so a crash loop closes that Tab
    // and nothing else: the sibling Tab keeps its Content and the Pane.
    let closed = events.compactMap { event -> TabID? in
      if case .tabAutoClosed(let id, _) = event { return id }
      return nil
    }
    #expect(closed == [tabID])
    let worktree = manager.catalog.projects[0].worktrees[0]
    #expect(worktree.allTabs.map(\.id) == [sibling.tabID])
    #expect(worktree.panes.map(\.id) == [sibling.paneID])
    #expect(manager.catalog.content(sibling.contentID) != nil)
  }

  // MARK: - Pending restore consume-once

  @Test
  func consumeRestorePathReturnsSeededPathThenNil() {
    let (engine, _, _, _) = makeEngine()
    let contentID = ContentID()
    let url = URL(fileURLWithPath: "/tmp/snapshot-\(UUID().uuidString).bin")
    engine.pendingRestores[contentID] = url

    // First read returns the path and clears the entry.
    #expect(engine.consumeRestorePath(for: contentID) == url.path)
    // Second read for the same pane sees an empty map → nil (consume-once).
    #expect(engine.consumeRestorePath(for: contentID) == nil)
  }

  @Test
  func consumeRestorePathLeavesOtherPanesUnaffected() {
    let (engine, _, _, _) = makeEngine()
    let contentA = ContentID()
    let contentB = ContentID()
    let urlA = URL(fileURLWithPath: "/tmp/a.bin")
    let urlB = URL(fileURLWithPath: "/tmp/b.bin")
    engine.pendingRestores[contentA] = urlA
    engine.pendingRestores[contentB] = urlB

    // Consuming one pane's restore must not disturb the other's entry.
    #expect(engine.consumeRestorePath(for: contentA) == urlA.path)
    #expect(engine.consumeRestorePath(for: contentB) == urlB.path)
    #expect(engine.consumeRestorePath(for: contentA) == nil)
  }

  @Test
  func consumeRestorePathReturnsNilForAbsentPane() {
    let (engine, _, _, _) = makeEngine()
    #expect(engine.consumeRestorePath(for: ContentID()) == nil)
  }

  // MARK: - Subscribe-after-finish

  @Test
  func subscribeAfterFinishReturnsAlreadyFinishedStream() async {
    let (engine, _, _, _) = makeEngine()
    engine.finishEventStream()
    let stream = engine.events()
    var count = 0
    for await _ in stream { count += 1 }
    #expect(count == 0)
  }

  // MARK: - Viewport poll outcome (agent idle nudges)

  @Test
  func viewportPollEmitsChangedThenBoundedIdleNudges() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func outcome(_ text: String, _ previous: String?, quiet: TimeInterval) -> TerminalEngine.ViewportPollOutcome {
      TerminalEngine.viewportPollOutcome(
        text: text, previous: previous, changedAt: t0, now: t0.addingTimeInterval(quiet)
      )
    }

    // First snapshot for a pane (no baseline) → changed.
    #expect(
      TerminalEngine.viewportPollOutcome(text: "spinner", previous: nil, changedAt: nil, now: t0)
        == .changed
    )
    // Live cue moved → changed.
    #expect(outcome("b", "a", quiet: 0.3) == .changed)

    // Quiet within the settle window → idle nudge carrying the quiet duration.
    if case .idleNudge(let duration) = outcome("a", "a", quiet: 0.3) {
      #expect(abs(duration - 0.3) < 0.001)
    } else {
      Issue.record("expected an idle nudge within the settle window")
    }

    // Quiet past the hold but still within the window → must keep nudging:
    // this is the tick that settles the badge.
    let pastHold = PaneAttentionInterpreter.agentWorkingHold + 0.3
    if case .idleNudge = outcome("a", "a", quiet: pastHold) {
    } else {
      Issue.record("expected a nudge to fire after the hold expires")
    }

    // Quiet beyond the window → silent (no forever-ticking for an idle pane).
    #expect(outcome("a", "a", quiet: TerminalEngine.idleNudgeWindow + 0.5) == .quiet)
  }

  @Test
  func idleNudgeWindowOutlastsAgentWorkingHold() {
    // The nudges only fix the badge if at least one fires *after* the hold
    // expires, so the window must strictly exceed the hold.
    #expect(TerminalEngine.idleNudgeWindow > PaneAttentionInterpreter.agentWorkingHold)
  }

  // MARK: - Foreground-job re-delivery (ghost-binding release)

  @Test
  func foregroundJobRedeliversToRetireStaleBinding() {
    // A genuine change always emits, regardless of binding/agent state.
    #expect(
      TerminalEngine.shouldRedeliverForegroundJob(
        changed: true, paneIsBound: false, foregroundIsStaleNonAgent: false))
    #expect(
      TerminalEngine.shouldRedeliverForegroundJob(
        changed: true, paneIsBound: true, foregroundIsStaleNonAgent: true))

    // The ghost case: a bound pane whose foreground has settled on a
    // non-agent program keeps re-delivering the *unchanged* job so the
    // binder's release hysteresis can retire the stale binding.
    #expect(
      TerminalEngine.shouldRedeliverForegroundJob(
        changed: false, paneIsBound: true, foregroundIsStaleNonAgent: true))

    // Healthy agent pane (foreground still an agent) → no churn.
    #expect(
      !TerminalEngine.shouldRedeliverForegroundJob(
        changed: false, paneIsBound: true, foregroundIsStaleNonAgent: false))

    // Unbound pane with a steady non-agent foreground → nothing to retire.
    #expect(
      !TerminalEngine.shouldRedeliverForegroundJob(
        changed: false, paneIsBound: false, foregroundIsStaleNonAgent: true))
  }
}
