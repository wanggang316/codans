import CodansCore
import Foundation

/// Decides which hidden pane surfaces may be detached to give their GPU and
/// thread resources back. Each live libghostty surface holds window-sized
/// Metal swap-chain buffers plus four threads, and nothing frees them while
/// the pane stays open; a pane's zmx daemon keeps the shell alive, so a
/// detached pane re-attaches on demand exactly like a pane restored after
/// a relaunch.
///
/// Pure on purpose: the engine gathers the inputs, this type only judges.
nonisolated struct SurfaceReclaimPolicy: Equatable, Sendable {
  /// How long a pane must stay out of every window before it is a candidate.
  var hiddenThreshold: TimeInterval = 20 * 60
  /// How long a pane's visible grid must stay unchanged. A hidden pane that
  /// still repaints is doing work the user may be waiting on.
  var quietThreshold: TimeInterval = 60

  /// Gap between sweeps; half the hidden threshold when that is short, so a
  /// scaled-down run still reclaims promptly.
  var sweepInterval: TimeInterval { min(60, max(0.5, hiddenThreshold / 2)) }

  init(hiddenThreshold: TimeInterval = 20 * 60, quietThreshold: TimeInterval = 60) {
    self.hiddenThreshold = hiddenThreshold
    self.quietThreshold = quietThreshold
  }

  /// Policy from `CODANS_SURFACE_RECLAIM_SECONDS`: the hidden threshold in
  /// seconds. The quiet threshold only shrinks with it, never grows. Nil for
  /// an unset or non-positive value, which keeps the built-in defaults.
  init?(overrideSeconds raw: String?) {
    guard let raw, let seconds = TimeInterval(raw), seconds > 0 else { return nil }
    self.init(hiddenThreshold: seconds, quietThreshold: min(60, seconds))
  }

  struct Candidate: Equatable, Sendable {
    var hiddenFor: TimeInterval
    var quietFor: TimeInterval
    /// Latest foreground sample; nil or empty means "not observed yet".
    var foregroundJob: ForegroundJob?
    /// Remote panes keep an ssh tunnel under their surface; detaching it
    /// would drop the tunnel for no memory gain worth the risk.
    var isRemote: Bool
    var isSurfaceReady: Bool
    /// App-level veto: a mid-turn agent or a queued command.
    var isVetoed: Bool
  }

  func shouldReclaim(_ candidate: Candidate) -> Bool {
    guard candidate.isSurfaceReady, !candidate.isRemote, !candidate.isVetoed else { return false }
    guard candidate.hiddenFor >= hiddenThreshold, candidate.quietFor >= quietThreshold else {
      return false
    }
    // An agent holds the foreground for its whole life and is not a running
    // command; only a non-agent, non-shell program counts as work in flight.
    guard let job = candidate.foregroundJob, !job.isEmpty else { return false }
    return !ForegroundJobClassifier.indicatesRunningCommand(job)
  }
}
