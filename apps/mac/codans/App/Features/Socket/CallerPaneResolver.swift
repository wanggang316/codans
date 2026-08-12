import Darwin
import Foundation
import CodansCore

/// Attribute a connecting CLI process to the pane it was launched from by
/// walking the caller's process ancestry against the live pane → shell-PID
/// map. This is kernel ground truth: it keeps working when a subshell,
/// wrapper, or env-scrubbing tool dropped `CODANS_PANE_ID`, and it can
/// never name a pane the caller is not actually running inside.
///
/// Each pane's shell lives under its zmx daemon, so a `codans` invocation
/// made inside a pane is a descendant of that daemon's shell child — the
/// PID `PaneSurface.childProcessID()` reports. Walking parent links from
/// the socket peer PID therefore lands on exactly one pane shell (or on
/// launchd for callers that are not inside any pane).
nonisolated enum CallerPaneResolver {
  /// Cap on parent-link hops. Real caller chains are a handful deep
  /// (shell → agent → subshell → cli); 64 is far beyond anything
  /// legitimate and bounds the walk if the kernel ever reports a
  /// pathological chain.
  private static let maxDepth = 64

  /// Walk `callerPID`'s ancestry (including itself) and return the first
  /// pane whose shell PID appears on the chain. `parentOf` is injectable
  /// for tests; production uses the sysctl-backed `parentPID(of:)`.
  static func resolve(
    callerPID: pid_t,
    paneByShellPID: [pid_t: PaneID],
    parentOf: (pid_t) -> pid_t? = CallerPaneResolver.parentPID(of:)
  ) -> PaneID? {
    guard callerPID > 0, !paneByShellPID.isEmpty else { return nil }
    var pid = callerPID
    var visited = Set<pid_t>()
    for _ in 0..<maxDepth {
      if let pane = paneByShellPID[pid] { return pane }
      // A repeated PID means the parent chain looped (PID reuse mid-walk);
      // bail rather than spin.
      guard visited.insert(pid).inserted else { return nil }
      guard let parent = parentOf(pid), parent > 1, parent != pid else { return nil }
      pid = parent
    }
    return nil
  }

  /// Parent PID via `sysctl KERN_PROC_PID`. Returns nil when the process
  /// is gone (the caller exited mid-walk) — sysctl then reports success
  /// with an empty buffer, which the `p_pid` echo check catches.
  static func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    let rc = mib.withUnsafeMutableBufferPointer { buffer in
      sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
    }
    guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    return info.kp_eproc.e_ppid
  }
}
