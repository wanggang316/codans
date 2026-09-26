import CodansCore
import Foundation
import Observation

/// Stores accepted Agent facts separately from attention and display hysteresis.
/// Only instance-tagged live observations can authorize automatic recovery.
@MainActor
@Observable
final class AgentStateStore {
  struct AgentEntry: Equatable {
    let kind: AgentKind
    var sessionID: String?
    var state: AgentRuntimeState
    var lastTransitionAt: Date
    var binding: AgentBinding?
    var bindingIsValid = false
    var observation: AgentObservation?
    var externalInputRevision: UInt64 = 0
    var recoverySuppressed = false
    var hasResidualDraft = false

    var recoveryEligible: Bool {
      guard bindingIsValid, !recoverySuppressed, !hasResidualDraft,
        let binding, let observation, observation.instanceID == binding.instanceID,
        case .error = observation.state
      else { return false }
      return true
    }
  }

  /// Wire/UI projection. Finished is unseen completion, not an execution state.
  enum AgentRuntimeState: String, CaseIterable, Equatable, Sendable {
    case unknown, idle, working, blocked, error, finished

    var isMidTask: Bool { self == .working || self == .blocked }
  }

  private struct Scratch {
    var tracker: TerminalObservationTracker
    var text: String?
    var parsed: TerminalParseResult?
    var lastSnapshotSequence: UInt64 = 0
    var lastWorkingAt: Date?
    var displayActivity: PaneAttentionInterpreter.AgentActivityState = .unknown
    var seen = true
    var title: String?
    var awaitingFirstClassification = false
    // The predecessor may have painted a final banner after its last capture.
    // The first replacement frame cannot claim ownership of any residual banner.
    var needsReplacementBaseline = false

    init(instanceID: AgentInstanceID = AgentInstanceID(), excluded: Set<ErrorBannerSignature> = []) {
      tracker = TerminalObservationTracker(instanceID: instanceID, excludedErrorBanners: excluded)
    }
  }

  private(set) var entries: [PaneID: AgentEntry] = [:]
  private var scratch: [PaneID: Scratch] = [:]
  private let focusedPane: @MainActor () -> PaneID?
  private let now: () -> Date

  init(focusedPane: @escaping @MainActor () -> PaneID?, now: @escaping () -> Date = Date.init) {
    self.focusedPane = focusedPane
    self.now = now
  }

  func onTerminalEvent(_ event: TerminalEvent) {
    switch event {
    case .paneAgentSnapshot(let snapshot):
      accept(snapshot)
    case .paneViewportChanged(let paneID, let text):
      // Untagged snapshots support display-only/remote bindings, never recovery.
      guard entries[paneID]?.binding == nil else { return }
      apply(text, paneID: paneID, observedAt: now())
    case .paneIdle(let paneID, _):
      refresh(paneID)
    case .paneExited(let paneID, _, _), .paneCrashed(let paneID, _), .paneClosedByTab(let paneID, _):
      onAgentUnbound(paneID)
    case .paneInfoChanged(let paneID, .title(let title)):
      var value = scratch[paneID] ?? Scratch()
      value.title = title
      scratch[paneID] = value
    default:
      break
    }
  }

  /// Compatibility/display-only binding, including remote panes without local identity.
  func onAgentBound(
    _ paneID: PaneID, kind: AgentKind, sessionID: String?, assumeUserInputSeen: Bool = false
  ) {
    if let entry = entries[paneID], entry.kind == kind, entry.sessionID == sessionID,
      entry.binding != nil
    {
      return
    }
    let previous = entries[paneID]
    if let previous, previous.kind != kind || previous.sessionID != sessionID {
      let old = scratch[paneID]
      var fresh = Scratch(excluded: old?.tracker.visibleErrorBanners ?? [])
      fresh.title = old?.title
      scratch[paneID] = fresh
    }
    if scratch[paneID] == nil { scratch[paneID] = Scratch() }
    entries[paneID] = AgentEntry(
      kind: kind, sessionID: sessionID, state: previous?.state ?? .unknown,
      lastTransitionAt: previous?.lastTransitionAt ?? now())
    if let text = scratch[paneID]?.text { apply(text, paneID: paneID, observedAt: now()) } else { refresh(paneID) }
  }

  func onAgentBound(_ binding: AgentBinding, assumeUserInputSeen: Bool = false) {
    let paneID = binding.paneID
    if var entry = entries[paneID], entry.binding?.instanceID == binding.instanceID {
      entry.binding = binding
      entry.sessionID = binding.sessionID
      entry.bindingIsValid = true
      entries[paneID] = entry
      return
    }
    let old = scratch[paneID]
    var fresh = Scratch(
      instanceID: binding.instanceID, excluded: old?.tracker.visibleErrorBanners ?? [])
    fresh.title = old?.title
    fresh.needsReplacementBaseline = entries[paneID]?.binding != nil
    scratch[paneID] = fresh
    entries[paneID] = AgentEntry(
      kind: binding.kind, sessionID: binding.sessionID, state: .unknown,
      lastTransitionAt: now(), binding: binding, bindingIsValid: true)
  }

  func onBindingValidityChanged(paneID: PaneID, valid: Bool) {
    guard var entry = entries[paneID] else { return }
    entry.bindingIsValid = valid
    entries[paneID] = entry
  }

  func onExternalInput(_ paneID: PaneID, revision: UInt64) {
    guard var entry = entries[paneID], var value = scratch[paneID] else { return }
    entry.externalInputRevision = revision
    entry.recoverySuppressed = false
    value.tracker.recordInput()
    value.seen = true
    value.lastWorkingAt = nil
    value.displayActivity = .unknown
    value.awaitingFirstClassification = false
    scratch[paneID] = value
    entries[paneID] = entry
    refresh(paneID)
  }

  /// Kept for callers/tests that directly model user interaction.
  func onPaneKeyboardActivity(_ paneID: PaneID) {
    onExternalInput(paneID, revision: (entries[paneID]?.externalInputRevision ?? 0) &+ 1)
  }

  func onPaneFocused(_ paneID: PaneID) {
    guard var value = scratch[paneID] else { return }
    value.seen = true
    scratch[paneID] = value
    refresh(paneID)
  }

  func cancelRecovery(for paneID: PaneID) {
    guard var entry = entries[paneID] else { return }
    entry.recoverySuppressed = true
    entries[paneID] = entry
  }

  func setResidualDraft(_ exists: Bool, for paneID: PaneID) {
    guard var entry = entries[paneID] else { return }
    entry.hasResidualDraft = exists
    entries[paneID] = entry
  }

  func onAgentUnbound(_ paneID: PaneID) {
    entries.removeValue(forKey: paneID)
    scratch.removeValue(forKey: paneID)
  }

  func reconcileMembership(livePaneIDs: Set<PaneID>) {
    for paneID in Set(entries.keys).union(scratch.keys) where !livePaneIDs.contains(paneID) {
      onAgentUnbound(paneID)
    }
  }

  func seedRestored(_ records: [(paneID: PaneID, kind: AgentKind, state: AgentRuntimeState)]) {
    for record in records {
      entries[record.paneID] = AgentEntry(
        kind: record.kind, sessionID: nil, state: record.state, lastTransitionAt: now())
      var value = Scratch()
      value.awaitingFirstClassification = true
      scratch[record.paneID] = value
    }
  }

  func title(for paneID: PaneID) -> String? { scratch[paneID]?.title }

  private func accept(_ snapshot: AgentTerminalSnapshot) {
    let paneID = snapshot.binding.paneID
    guard let entry = entries[paneID], entry.binding == snapshot.binding,
      var value = scratch[paneID], snapshot.sequence > value.lastSnapshotSequence
    else { return }
    value.lastSnapshotSequence = snapshot.sequence
    scratch[paneID] = value
    onBindingValidityChanged(paneID: paneID, valid: true)
    apply(snapshot.text, paneID: paneID, observedAt: snapshot.observedAt)
  }

  private func apply(_ text: String, paneID: PaneID, observedAt: Date) {
    var value = scratch[paneID] ?? Scratch()
    let changed = value.text != text
    value.text = text
    if let entry = entries[paneID] {
      let parsed =
        (!changed ? value.parsed : nil)
        ?? AgentRegistry.definition(for: entry.kind).terminalParser.parse(text)
      value.parsed = parsed
      if value.needsReplacementBaseline {
        value.tracker = TerminalObservationTracker(
          instanceID: value.tracker.instanceID,
          excludedErrorBanners: parsed.evidence.visibleErrorBanners)
        value.needsReplacementBaseline = false
      }
      _ = value.tracker.accept(parsed, observedAt: observedAt)
      value.awaitingFirstClassification = false
    }
    scratch[paneID] = value
    refresh(paneID)
  }

  private func refresh(_ paneID: PaneID) {
    guard var value = scratch[paneID], var entry = entries[paneID] else { return }
    entry.observation = value.tracker.lastObservation
    guard !value.awaitingFirstClassification else { return }
    let raw = Self.activity(entry.observation?.state ?? .unknown)
    let previous = value.displayActivity
    let displayed = PaneAttentionInterpreter.stabilizeAgentActivity(
      previous: previous, raw: raw, now: now(), lastWorkingAt: &value.lastWorkingAt)
    if displayed == .error || displayed == .unknown || displayed == .blocked { value.seen = true }
    if focusedPane() == paneID {
      value.seen = true
    } else if previous == .working, displayed == .idle {
      value.seen = false
    }
    value.displayActivity = displayed
    let next: AgentRuntimeState
    switch displayed {
    case .unknown: next = .unknown
    case .idle: next = value.seen ? .idle : .finished
    case .working: next = .working
    case .blocked: next = .blocked
    case .error: next = .error
    }
    if entry.state != next {
      entry.state = next
      entry.lastTransitionAt = now()
    }
    scratch[paneID] = value
    entries[paneID] = entry
  }

  private static func activity(_ state: AgentState) -> PaneAttentionInterpreter.AgentActivityState {
    switch state {
    case .unknown: return .unknown
    case .idle: return .idle
    case .working: return .working
    case .blocked: return .blocked
    case .error: return .error
    }
  }
}
