import Foundation

/// Transient message shown in the Worktree Status Bar (titlebar center slot).
///
/// Three severities. `inProgress` never auto-dismisses — the emitter must push
/// a terminal state to end it. `success` and `warning` are short-lived; the
/// owning reducer schedules an auto-clear (3 s / 8 s in `StatusBarFeature`).
/// `error` is intentionally absent: fatal errors route through sheets/banners,
/// not a one-line slot that can be covered by the next push.
///
/// Lives in `CodansCore` so any future feature (run-script, batched
/// reconcile, IPC-delivered events) can construct values without depending
/// on the app target.
public nonisolated enum StatusToast: Equatable, Sendable {
  case inProgress(String)
  case success(String)
  case warning(String)

  public var message: String {
    switch self {
    case .inProgress(let m), .success(let m), .warning(let m): return m
    }
  }
}
