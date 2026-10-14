import CodansIPC
import Foundation
import Observation
import os

/// Server side of `events.subscribe`: watches the hierarchy and agent-state
/// projections and fans changes out to every subscriber — the local CLI and
/// paired phones alike.
///
/// Changes are coalesced per topic: the first change after a quiet period
/// opens a window (`coalescingWindow`, ~250 ms); when it closes the hub
/// recomputes that topic's projection once and hands the value to every
/// subscriber. Recomputing re-arms observation in the same step, so no
/// change can slip between "compute" and "watch again". A subscriber keeps
/// only the latest value per topic, so a slow reader costs one pending
/// frame per topic however chatty the source is.
///
/// Observation is armed only while someone is subscribed; with no
/// subscribers the hub does no work.
@MainActor
final class EventHub {
  /// Wire projections of live state. Read inside `withObservationTracking`,
  /// so whatever observable state they touch is what the hub watches.
  struct Sources {
    var hierarchy: @MainActor () -> IPC.HierarchySummary
    var agents: @MainActor () -> [IPC.AgentStateEntry]
  }

  private let sources: Sources
  private let clock: any Clock<Duration>
  let coalescingWindow: Duration
  let heartbeatInterval: Duration
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "events")

  /// Weak so a dropped stream cannot keep its subscription registered.
  private var subscriptions: [ObjectIdentifier: WeakSubscription] = [:]
  /// Topics whose observation is currently armed.
  private var armed: Set<IPC.EventTopic> = []
  /// Topics with a coalescing window open.
  private var flushing: Set<IPC.EventTopic> = []

  init(
    sources: Sources,
    clock: any Clock<Duration> = ContinuousClock(),
    coalescingWindow: Duration = .milliseconds(250),
    heartbeatInterval: Duration = .seconds(30)
  ) {
    self.sources = sources
    self.clock = clock
    self.coalescingWindow = coalescingWindow
    self.heartbeatInterval = heartbeatInterval
  }

  var subscriberCount: Int {
    subscriptions.values.count { $0.value != nil }
  }

  /// Registers a subscriber. Its first frame is a snapshot of every
  /// requested topic, computed when the stream is first pulled.
  func subscribe(topics: Set<IPC.EventTopic>) -> EventSubscription {
    let subscription = EventSubscription(hub: self, topics: topics, clock: clock, heartbeat: heartbeatInterval)
    subscriptions[ObjectIdentifier(subscription)] = WeakSubscription(value: subscription)
    for topic in topics where !armed.contains(topic) {
      _ = observe(topic)
    }
    logger.info("subscriber added (\(self.subscriberCount, privacy: .public) total)")
    return subscription
  }

  func unsubscribe(_ subscription: EventSubscription) {
    guard subscriptions.removeValue(forKey: ObjectIdentifier(subscription)) != nil else { return }
    logger.info("subscriber removed (\(self.subscriberCount, privacy: .public) total)")
  }

  /// A source changed. Opens the topic's coalescing window unless one is
  /// already open; the flush at its end sees every change made meanwhile.
  func sourceChanged(_ topic: IPC.EventTopic) {
    armed.remove(topic)
    guard !flushing.contains(topic) else { return }
    flushing.insert(topic)
    Task { [weak self, clock, coalescingWindow] in
      try? await clock.sleep(for: coalescingWindow)
      self?.flush(topic)
    }
  }

  /// Current value of `topic`, for a snapshot.
  func current(_ topic: IPC.EventTopic) -> ProjectedValue {
    armed.contains(topic) ? project(topic) : observe(topic)
  }

  // MARK: - Internals

  private func flush(_ topic: IPC.EventTopic) {
    flushing.remove(topic)
    let listeners = subscriptions.values.compactMap(\.value).filter { $0.topics.contains(topic) }
    subscriptions = subscriptions.filter { $0.value.value != nil }
    // Nobody left to tell: stay disarmed until the next subscriber.
    guard !listeners.isEmpty else { return }
    let value = observe(topic)
    for listener in listeners {
      listener.receive(value)
    }
  }

  /// Computes `topic` while tracking what it reads, and arms a one-shot
  /// change callback on exactly that state.
  private func observe(_ topic: IPC.EventTopic) -> ProjectedValue {
    armed.insert(topic)
    return withObservationTracking {
      project(topic)
    } onChange: { [weak self] in
      // Fires on willSet, possibly mid-mutation; act after it lands.
      Task { @MainActor [weak self] in self?.sourceChanged(topic) }
    }
  }

  private func project(_ topic: IPC.EventTopic) -> ProjectedValue {
    switch topic {
    case .hierarchy: return .hierarchy(sources.hierarchy())
    case .agents: return .agents(sources.agents())
    }
  }

  enum ProjectedValue {
    case hierarchy(IPC.HierarchySummary)
    case agents([IPC.AgentStateEntry])
  }

  private struct WeakSubscription {
    weak var value: EventSubscription?
  }
}

/// One `events.subscribe` stream. Pull-based: each frame is produced when
/// the consumer asks for it, from the latest projected values, so frames
/// never pile up behind a slow writer.
@MainActor
final class EventSubscription {
  let topics: Set<IPC.EventTopic>
  private weak var hub: EventHub?
  private let clock: any Clock<Duration>
  private let heartbeat: Duration

  private var seq = 0
  private var snapshotSent = false
  private var finished = false
  /// Latest value per topic not yet turned into a frame.
  private var pendingHierarchy: IPC.HierarchySummary?
  private var pendingAgents: [IPC.AgentStateEntry]?
  /// What the subscriber has already been told, to compute deltas.
  private var sentHierarchy: IPC.HierarchySummary?
  private var sentAgents: [String: IPC.AgentStateEntry] = [:]
  private var waiter: CheckedContinuation<Void, Never>?
  private var heartbeatTimer: Task<Void, Never>?
  /// Why the last wait ended: a value (or cancellation) versus a quiet
  /// heartbeat interval.
  private var wokeForChange = true

  init(hub: EventHub, topics: Set<IPC.EventTopic>, clock: any Clock<Duration>, heartbeat: Duration) {
    self.hub = hub
    self.topics = topics
    self.clock = clock
    self.heartbeat = heartbeat
  }

  /// The next frame, or nil once the subscription ends (the consumer's
  /// task was cancelled or the hub went away).
  func next() async -> IPC.EventFrame? {
    if !snapshotSent {
      snapshotSent = true
      return makeFrame(.snapshot(snapshot()))
    }
    while !finished, !Task.isCancelled {
      if let payload = takePendingPayload() {
        return makeFrame(payload)
      }
      if hub == nil { break }
      if await !waitForChange() {
        return makeFrame(.heartbeat)
      }
    }
    end()
    return nil
  }

  /// The frames as the router's streaming outcome wants them.
  nonisolated func jsonFrames() -> AsyncStream<JSONValue> {
    AsyncStream(
      unfolding: { [self] in
        guard let frame = await self.next() else { return nil }
        do {
          return try JSONValue.encoded(frame)
        } catch {
          await self.end()
          return nil
        }
      },
      onCancel: { [self] in
        Task { @MainActor in self.end() }
      })
  }

  /// A fresh projected value from the hub; replaces any value still
  /// pending for that topic.
  func receive(_ value: EventHub.ProjectedValue) {
    switch value {
    case .hierarchy(let summary): pendingHierarchy = summary
    case .agents(let entries): pendingAgents = entries
    }
    wake(changed: true)
  }

  func end() {
    guard !finished else { return }
    finished = true
    wake(changed: true)
    hub?.unsubscribe(self)
  }

  // MARK: - Internals

  private func snapshot() -> IPC.EventsSnapshot {
    var hierarchy: IPC.HierarchySummary?
    var agents: [IPC.AgentStateEntry]?
    if topics.contains(.hierarchy), case .hierarchy(let summary)? = hub?.current(.hierarchy) {
      hierarchy = summary
      sentHierarchy = summary
    }
    if topics.contains(.agents), case .agents(let entries)? = hub?.current(.agents) {
      agents = entries
      sentAgents = Dictionary(entries.map { ($0.paneID, $0) }, uniquingKeysWith: { _, last in last })
    }
    // Anything that arrived before the snapshot is already in it.
    pendingHierarchy = nil
    pendingAgents = nil
    return IPC.EventsSnapshot(hierarchy: hierarchy, agents: agents)
  }

  /// Turns the pending values into at most one payload, skipping values
  /// that turn out identical to what was already sent.
  private func takePendingPayload() -> IPC.EventPayload? {
    if let summary = pendingHierarchy {
      pendingHierarchy = nil
      if summary != sentHierarchy {
        sentHierarchy = summary
        return .hierarchyChanged(summary)
      }
    }
    if let entries = pendingAgents {
      pendingAgents = nil
      if let delta = agentDelta(to: entries) {
        return .agentStatesChanged(delta)
      }
    }
    return nil
  }

  private func agentDelta(to entries: [IPC.AgentStateEntry]) -> IPC.AgentStatesDelta? {
    var next: [String: IPC.AgentStateEntry] = [:]
    var upserted: [IPC.AgentStateEntry] = []
    for entry in entries where next[entry.paneID] == nil {
      next[entry.paneID] = entry
      if sentAgents[entry.paneID] != entry { upserted.append(entry) }
    }
    let removed = sentAgents.keys.filter { next[$0] == nil }.sorted()
    guard !upserted.isEmpty || !removed.isEmpty else { return nil }
    sentAgents = next
    return IPC.AgentStatesDelta(upserted: upserted, removedPaneIDs: removed)
  }

  private func makeFrame(_ payload: IPC.EventPayload) -> IPC.EventFrame {
    seq += 1
    return IPC.EventFrame(seq: seq, payload: payload)
  }

  /// Suspends until a value arrives (true) or the heartbeat interval
  /// passes with nothing to send (false). Cancellation wakes it too.
  private func waitForChange() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        waiter = continuation
        heartbeatTimer = Task { [weak self, clock, heartbeat] in
          do {
            try await clock.sleep(for: heartbeat)
          } catch {
            return
          }
          self?.wake(changed: false)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.wake(changed: true) }
    }
    return wokeForChange
  }

  private func wake(changed: Bool) {
    guard let continuation = waiter else { return }
    waiter = nil
    if changed { heartbeatTimer?.cancel() }
    heartbeatTimer = nil
    wokeForChange = changed
    continuation.resume()
  }
}
