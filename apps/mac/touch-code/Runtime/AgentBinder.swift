import Foundation
import OSLog
import TouchCodeCore

private let binderLogger = Logger(
  subsystem: "com.touch-code.activeagents", category: "binder"
)

/// Identifies which coding agent (Claude Code / Codex / pi) is running in
/// each pane and persists that decision via `HierarchyClient.setPaneAgentKind`.
///
/// The classifier (`AgentKindPatterns.classify`) is a pure function over up
/// to three free-form signals — `Pane.initialCommand`, the latest terminal
/// title, and an OSC-9 notification title. `AgentBinder` is the runtime
/// glue that wires those signals to the writer with a stickiness policy:
///
/// - First positive classification wins (`paneCreated` / `titleChanged` /
///   `desktopNotification`).
/// - Once bound, only an OSC 133 prompt-end event (`.promptReturned`) can
///   rebind to a different `AgentKind`. Title / OSC-9 events arriving on
///   an already-bound pane are ignored — the title may briefly shift to a
///   subprocess name (`"vim"`, `"less"`) without meaning the agent is gone.
/// - `unbind(_:)` is the only path that clears `agentKind`; lifecycle
///   teardown (pane exited / crashed / closed-by-tab) calls it.
///
/// The classifier may return nil (no signal yielded a hit). On
/// `.paneCreated` we still write that nil through so a pane that never
/// matches stays explicitly unbound; on every other trigger nil is a
/// "no signal" and we leave the existing binding (or absence) alone.
///
/// Writes are suppressed when the result equals the existing value —
/// `HierarchyClient.setPaneAgentKind` is already idempotent (T2) but
/// short-circuiting here keeps logs and traces clean.
@MainActor
final class AgentBinder {
  /// Why `consider(...)` is being called. The sticky-rule branch in
  /// `consider(...)` keys off this — see the per-case logic there.
  enum Trigger: Equatable {
    /// Pane was just created. The only trigger that can write a nil
    /// classify result (records the absence of any matching signal).
    case paneCreated
    /// Terminal title changed (OSC 0/2 or libghostty-derived title).
    case titleChanged
    /// OSC 9 desktop-notification arrived. Carries its own title/body
    /// payload, which the binder feeds into the classifier's
    /// `notificationTitle` channel for this single call.
    case desktopNotification(title: String, body: String)
    /// OSC 133 prompt-end (shell prompt is back, command finished). The
    /// only trigger that can rebind an already-bound pane — a stale
    /// agent identification gets a chance to correct itself when control
    /// returns to the shell.
    case promptReturned
  }

  private let client: HierarchyClient
  private let currentAgentKind: @MainActor (PaneID) -> AgentKind?
  private let paneInitialCommand: @MainActor (PaneID) -> String?
  private let paneTitle: @MainActor (PaneID) -> String?
  /// Optional T6 hook: fired immediately AFTER `setPaneAgentKind` lands
  /// a non-nil binding. AppState wires this to `AgentRegistry.onAgentBound`
  /// so the ActiveAgents UI learns about the new agent without a separate
  /// observation pass. Default no-op keeps existing tests / callers
  /// untouched.
  private let agentBoundHandler: @MainActor (PaneID, AgentKind, String?) -> Void
  /// Companion of `agentBoundHandler` — fires on `unbind(_:)` and on any
  /// path that writes a nil binding through `setPaneAgentKind`. AppState
  /// wires this to `AgentRegistry.onAgentUnbound`.
  private let agentUnboundHandler: @MainActor (PaneID) -> Void

  init(
    client: HierarchyClient,
    currentAgentKind: @escaping @MainActor (PaneID) -> AgentKind?,
    paneInitialCommand: @escaping @MainActor (PaneID) -> String?,
    paneTitle: @escaping @MainActor (PaneID) -> String?,
    agentBoundHandler: @escaping @MainActor (PaneID, AgentKind, String?) -> Void = { _, _, _ in },
    agentUnboundHandler: @escaping @MainActor (PaneID) -> Void = { _ in }
  ) {
    self.client = client
    self.currentAgentKind = currentAgentKind
    self.paneInitialCommand = paneInitialCommand
    self.paneTitle = paneTitle
    self.agentBoundHandler = agentBoundHandler
    self.agentUnboundHandler = agentUnboundHandler
  }

  /// Re-run classification for this pane in response to the given trigger
  /// and write only when the result differs from the current binding.
  /// See the type-level doc comment for the full sticky-rule contract.
  func consider(paneID: PaneID, trigger: Trigger) {
    let existing = currentAgentKind(paneID)

    // Pull live signals. `initialCommand` is only meaningful while the
    // pane is fresh (Pane.initialCommand is decoded as nil on relaunch),
    // so a nil here is "no signal", not "unbind".
    let initialCommand = paneInitialCommand(paneID)
    let title = paneTitle(paneID)
    let notificationTitle: String? = {
      if case .desktopNotification(let notifTitle, _) = trigger { return notifTitle }
      return nil
    }()

    let classified = AgentKindPatterns.classify(
      initialCommand: initialCommand,
      title: title,
      notificationTitle: notificationTitle
    )

    switch trigger {
    case .paneCreated:
      // Initial bind: write whatever classify says, including nil. The
      // `existing == nil` guard is defensive — pane-creation events for
      // a pane that already has a binding should never happen.
      guard existing == nil else { return }
      writeIfChanged(paneID: paneID, existing: existing, next: classified, reason: "paneCreated")

    case .titleChanged, .desktopNotification:
      // Sticky: only fill in a missing binding. Title shifts on an
      // already-bound pane are not allowed to rewrite — could be a
      // transient subprocess (vim/less) inside the agent's shell.
      guard existing == nil else {
        binderLogger.debug(
          "consider trigger=\(String(describing: trigger), privacy: .public) pane already bound, skipping"
        )
        return
      }
      // Only call through when classify produced a hit; nil here means
      // "no signal yet", not "unbind". Leave the field at nil.
      guard let next = classified else { return }
      writeIfChanged(
        paneID: paneID, existing: existing, next: next,
        reason: triggerLogTag(trigger)
      )

    case .promptReturned:
      // Rebind path. Nil classify is treated as "no signal at the
      // prompt" — don't unbind a previously-identified agent just
      // because the prompt came back quiet.
      guard let next = classified else { return }
      // Same-kind classify is a true no-op (also caught by
      // writeIfChanged, but logged distinctly here).
      guard next != existing else { return }
      writeIfChanged(
        paneID: paneID, existing: existing, next: next, reason: "promptReturned"
      )
    }
  }

  /// Pane teardown: clear the agent binding. Always calls the writer; the
  /// underlying writer is idempotent so a never-bound pane costs only a
  /// snapshot read.
  func unbind(_ paneID: PaneID) {
    client.setPaneAgentKind(paneID, nil)
    agentUnboundHandler(paneID)
  }

  // MARK: - Helpers

  private func writeIfChanged(
    paneID: PaneID,
    existing: AgentKind?,
    next: AgentKind?,
    reason: String
  ) {
    guard existing != next else {
      binderLogger.debug(
        "no-op classify reason=\(reason, privacy: .public)"
      )
      return
    }
    if existing == nil {
      binderLogger.info(
        "bind reason=\(reason, privacy: .public) kind=\(next?.rawValue ?? "nil", privacy: .public)"
      )
    } else {
      binderLogger.info(
        "rebind reason=\(reason, privacy: .public) \(existing?.rawValue ?? "nil", privacy: .public) → \(next?.rawValue ?? "nil", privacy: .public)"
      )
    }
    client.setPaneAgentKind(paneID, next)
    // T6 hook — fire AFTER the writer so the registry observes the same
    // kind that just landed in the catalog. Session-id is not modelled
    // here yet (always nil); when `setPaneAgentSessionID` callers wake
    // up, plumb a third channel down through this hook.
    if let kind = next {
      agentBoundHandler(paneID, kind, nil)
    } else {
      agentUnboundHandler(paneID)
    }
  }

  private func triggerLogTag(_ trigger: Trigger) -> String {
    switch trigger {
    case .paneCreated: return "paneCreated"
    case .titleChanged: return "titleChanged"
    case .desktopNotification: return "desktopNotification"
    case .promptReturned: return "promptReturned"
    }
  }
}
