import CodansCore
import Foundation

/// One-shot SSH reachability check for a Server project's health reconcile.
/// Runs `ssh <BatchMode,ConnectTimeout> host true`: a live ControlMaster (an
/// open terminal) makes this a near-instant no-auth round-trip; a cold host
/// pays one TCP+handshake bounded by `ConnectTimeout`. `BatchMode=yes` fails
/// fast instead of blocking on a password / host-key prompt, so a truly
/// unreachable host reports `false` rather than hanging the reconcile.
///
/// This is the remote analogue of `ProjectReconciler`'s local
/// `FileManager.fileExists(atPath:)` stat — a remote path can't be stat'd
/// locally, so reachability of the host stands in for "the project's root is
/// still there".
nonisolated enum RemoteReachabilityProbe {
  static let timeout: Duration = .seconds(15)

  /// `true` when `ssh host true` exits 0. Any non-zero exit, timeout, or spawn
  /// failure is `false` — the caller maps that to `.failed(reason:)`.
  static func isReachable(
    host: RemoteHost,
    runner: any CommandRunner = FoundationCommandRunner()
  ) async -> Bool {
    // `true` is a POSIX builtin on every login shell, so no remote PATH lookup
    // is needed; `SSHCommand.invocation` still login-shell-wraps it, which is
    // harmless for a builtin and keeps the invocation identical in shape to the
    // git probes sharing this ControlMaster.
    let (executable, arguments) = SSHCommand.invocation(
      host: host,
      executable: "true",
      arguments: [],
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    let outcome = await runner.run(
      executable: executable,
      arguments: arguments,
      env: ProcessInfo.processInfo.environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: timeout,
      maxOutputBytes: 4096
    )
    if case .exited(let code, _, _, _) = outcome, code == 0 { return true }
    return false
  }
}
