import Foundation
import TouchCodeCore

/// Records the last user-keystroke timestamp per pane. Reads as
/// `[PaneID: Date]` snapshots that `NotificationDetector` feeds to
/// `PaneAttentionInterpreter.Context.lastUserKeystrokeAt` so the interpreter's
/// 1-second `userTypingRecently` suppression can actually fire on real
/// user input.
///
/// Why a side channel and not a TerminalEvent case: keystroke cadence is
/// human-scale (≤ ~10 Hz per pane), but routing through TerminalEvent
/// would force every event consumer (RootFeature, tests, future analytics)
/// to learn about a signal only the detector cares about. The tracker is
/// detector-local plumbing.
///
/// Owned by AppState; the GhosttySurfaceView key delivery site records
/// keystrokes; the detector reads snapshots when building per-event
/// interpreter contexts; teardown events purge entries.
@MainActor
public final class PaneKeyboardActivityTracker {
  private var lastByPane: [PaneID: Date] = [:]

  /// Process-global weak handle for the AppKit responder path. NSView
  /// subclasses (`GhosttySurfaceView`) cannot read SwiftUI's `@Environment`
  /// and the views are constructed deep inside `PaneSurface` / `TerminalEngine`,
  /// so a thread-the-needle constructor injection would touch every surface
  /// constructor. Mirrors the precedent set by `GhosttyRuntime.shared`.
  /// AppState's `bringUp` sets this once; nothing else writes it.
  public static weak var shared: PaneKeyboardActivityTracker?

  /// Optional T6 fan-out: fired AFTER `recordKey` updates the map.
  /// AppState wires this to `AgentStateStore.onPaneKeyboardActivity` so
  /// the AgentState state machine clears its sticky `waitingForInput`
  /// flag on real typing. The default no-op keeps the tracker
  /// detector-local for existing call sites that don't need the hook.
  public var onActivity: (@MainActor (PaneID) -> Void)?

  public init() {}

  /// Record a user key event delivered to `paneID` at `at`. Called from
  /// GhosttySurfaceView's key delivery site, before the bytes hand off
  /// to libghostty's PTY.
  public func recordKey(in paneID: PaneID, at: Date = Date()) {
    lastByPane[paneID] = at
    onActivity?(paneID)
  }

  /// Snapshot of all recorded timestamps. The detector calls this once
  /// per `TerminalEvent` to build a Context; the snapshot is a Dictionary
  /// copy (cheap — bounded by open panes, ≤ tens) so the detector can
  /// safely capture it into a per-call Context value.
  public func snapshot() -> [PaneID: Date] {
    lastByPane
  }

  /// Purge a pane's entry. Called from teardown branches (paneExited /
  /// paneCrashed / paneClosedByTab) so the map's upper bound is "open
  /// panes plus a handful in-flight" rather than monotonically growing.
  public func purge(_ paneID: PaneID) {
    lastByPane.removeValue(forKey: paneID)
  }
}
