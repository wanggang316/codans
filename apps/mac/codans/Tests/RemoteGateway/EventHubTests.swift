import ComposableArchitecture
import Foundation
import Observation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// `events.subscribe` on the server: snapshot first, then coalesced deltas
/// driven by observation of the sources. Every test that awaits a frame
/// carries a time limit, because a hung subscription would otherwise still
/// let the run report success.
@MainActor
struct EventHubTests {
  @Test(.timeLimit(.minutes(1)))
  func snapshotIsTheFirstFrame() async throws {
    let fixture = Fixture()
    fixture.sources.projects = ["alpha"]
    fixture.sources.agents = [Self.entry("p1", state: "working")]
    let subscription = fixture.hub.subscribe(topics: Set(IPC.EventTopic.allCases))

    let frame = try #require(await subscription.next())
    #expect(frame.seq == 1)
    guard case .snapshot(let snapshot) = frame.payload else {
      Issue.record("expected snapshot, got \(frame.payload)")
      return
    }
    #expect(snapshot.hierarchy?.projects.map(\.name) == ["alpha"])
    #expect(snapshot.agents == [Self.entry("p1", state: "working")])
  }

  @Test(.timeLimit(.minutes(1)))
  func burstWithinTheWindowCoalescesIntoOneFrame() async throws {
    let fixture = Fixture()
    fixture.sources.agents = [Self.entry("p1", state: "idle")]
    let subscription = fixture.hub.subscribe(topics: [.agents])
    _ = await subscription.next()

    let readsBefore = fixture.sources.agentReads
    fixture.sources.agents = [Self.entry("p1", state: "working")]
    fixture.sources.agents = [Self.entry("p1", state: "blocked")]
    fixture.sources.agents = [Self.entry("p1", state: "blocked"), Self.entry("p2", state: "idle")]
    let frame = try #require(await fixture.nextFrame(subscription))
    #expect(frame.seq == 2)
    #expect(
      frame.payload
        == .agentStatesChanged(
          IPC.AgentStatesDelta(
            upserted: [Self.entry("p1", state: "blocked"), Self.entry("p2", state: "idle")],
            removedPaneIDs: [])))
    // One recompute for the whole burst.
    #expect(fixture.sources.agentReads - readsBefore == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func slowReaderGetsOnlyTheLatestValue() async throws {
    let fixture = Fixture()
    fixture.sources.agents = [Self.entry("p1", state: "idle"), Self.entry("p2", state: "idle")]
    let subscription = fixture.hub.subscribe(topics: [.agents])
    _ = await subscription.next()

    // Two windows close while nobody is reading.
    fixture.sources.agents = [Self.entry("p1", state: "working"), Self.entry("p2", state: "idle")]
    await Task.megaYield()
    await fixture.clock.advance(by: .milliseconds(250))
    fixture.sources.agents = [Self.entry("p1", state: "idle")]
    await Task.megaYield()
    await fixture.clock.advance(by: .milliseconds(250))

    let frame = try #require(await fixture.nextFrame(subscription))
    // p1 went working → idle between reads, so it is unchanged from the
    // snapshot; only p2's removal is left to report.
    #expect(
      frame.payload == .agentStatesChanged(IPC.AgentStatesDelta(upserted: [], removedPaneIDs: ["p2"])))

    // Nothing else is queued: the next frame is the heartbeat.
    let heartbeat = try #require(await fixture.nextFrame(subscription, step: fixture.hub.heartbeatInterval))
    #expect(heartbeat.payload == .heartbeat)
  }

  @Test(.timeLimit(.minutes(1)))
  func topicsTheSubscriberDidNotAskForProduceNoFrames() async throws {
    let fixture = Fixture()
    let subscription = fixture.hub.subscribe(topics: [.hierarchy])
    let snapshot = try #require(await subscription.next())
    guard case .snapshot(let content) = snapshot.payload else {
      Issue.record("expected snapshot")
      return
    }
    #expect(content.agents == nil)

    fixture.sources.agents = [Self.entry("p9", state: "working")]
    await Task.megaYield()
    await fixture.clock.advance(by: .milliseconds(250))
    await Task.megaYield()
    fixture.sources.projects = ["beta"]

    // The agents change must not surface: the first frame is the hierarchy one.
    let frame = try #require(await fixture.nextFrame(subscription))
    guard case .hierarchyChanged(let summary) = frame.payload else {
      Issue.record("expected hierarchyChanged, got \(frame.payload)")
      return
    }
    #expect(summary.projects.map(\.name) == ["beta"])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingTheConsumerEndsTheSubscription() async throws {
    let fixture = Fixture()
    let subscription = fixture.hub.subscribe(topics: [.agents])
    _ = await subscription.next()
    #expect(fixture.hub.subscriberCount == 1)

    let pending = Task { await subscription.next() }
    await Task.megaYield()
    pending.cancel()
    #expect(await pending.value == nil)
    #expect(fixture.hub.subscriberCount == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func localClientReceivesTheSnapshotOverTheWire() async throws {
    let fixture = Fixture()
    fixture.sources.projects = ["wire"]
    let router = MethodRouter(
      systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")),
      eventHub: fixture.hub
    )
    let server = InMemoryIPCServer(router: router)
    server.start()
    defer { server.stop() }

    let hello = try JSONValue.encoded(HelloRequest(clientVersion: "1", clientBinary: "test"))
    try server.send(IPC.Request(id: "h", method: .systemHello, params: hello))
    _ = try await server.awaitResponse()
    try server.send(
      IPC.Request(
        id: "s", method: .eventsSubscribe,
        params: try JSONValue.encoded(IPC.EventsSubscribeRequest(topics: [.hierarchy])), stream: true))

    let response = try await server.awaitResponse()
    #expect(response.id == "s")
    #expect(response.stream)
    let frame = try #require(try response.result?.decoded(as: IPC.EventFrame.self))
    guard case .snapshot(let snapshot) = frame.payload else {
      Issue.record("expected snapshot, got \(frame.payload)")
      return
    }
    #expect(snapshot.hierarchy?.projects.map(\.name) == ["wire"])
  }

  @Test(.timeLimit(.minutes(1)))
  func unknownTopicIsInvalidParams() async throws {
    let router = MethodRouter(
      systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")),
      eventHub: Fixture().hub
    )
    let outcome = await router.route(
      IPC.Request(
        id: "s", method: .eventsSubscribe, params: .object(["topics": .array([.string("weather")])]),
        stream: true))
    guard case .failed(.invalidParams) = outcome else {
      Issue.record("expected invalidParams, got \(outcome)")
      return
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func emptyTopicListIsInvalidParams() async throws {
    let router = MethodRouter(
      systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")),
      eventHub: Fixture().hub
    )
    let outcome = await router.route(
      IPC.Request(
        id: "s", method: .eventsSubscribe, params: .object(["topics": .array([])]), stream: true))
    guard case .failed(.invalidParams) = outcome else {
      Issue.record("expected invalidParams, got \(outcome)")
      return
    }
  }

  // MARK: - Fixture

  @MainActor
  private struct Fixture {
    let sources = FakeSources()
    let clock = TestClock<Duration>()
    let hub: EventHub

    /// Pulls the next frame while stepping the test clock. A source change
    /// arms its coalescing window asynchronously, so a single `advance` can
    /// land before the window's sleep is registered and never wake it;
    /// stepping until delivery removes that race.
    func nextFrame(
      _ subscription: EventSubscription, step: Duration = .milliseconds(250)
    ) async -> IPC.EventFrame? {
      let delivered = LockIsolated<IPC.EventFrame??>(nil)
      let pending = Task {
        let frame = await subscription.next()
        delivered.setValue(.some(frame))
        return frame
      }
      for _ in 0..<40 where delivered.value == nil {
        await Task.megaYield()
        await clock.advance(by: step)
      }
      return await pending.value
    }

    init() {
      let sources = self.sources
      hub = EventHub(
        sources: EventHub.Sources(
          hierarchy: {
            IPC.HierarchySummary(
              projects: sources.projects.map {
                IPC.ProjectSummary(id: $0, name: $0, isRemote: false, selectedWorktreeID: nil, worktrees: [])
              },
              selectedProjectID: nil)
          },
          agents: {
            sources.agentReads += 1
            return sources.agents
          }
        ),
        clock: clock
      )
    }
  }

  static func entry(_ paneID: String, state: String) -> IPC.AgentStateEntry {
    IPC.AgentStateEntry(
      paneID: paneID, handle: nil, agent: "claude", agentName: "Claude Code", state: state,
      since: "2026-09-25T00:00:00Z", sessionID: nil, title: nil, projectID: "p", projectName: "p",
      worktreeID: "w", worktreeName: "w", tabID: "t", tabTitle: nil, isFocused: false)
  }
}

@MainActor
@Observable
private final class FakeSources {
  var projects: [String] = []
  var agents: [IPC.AgentStateEntry] = []
  @ObservationIgnored var agentReads = 0
}
