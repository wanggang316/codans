import Foundation
import TouchCodeCore
import os.log

/// Spawns a `zmx serve <paneID>` daemon for a pane and connects a
/// `ZmxClient` to its newly-created control socket. Owns the lookup of
/// the embedded `zmx` binary, the subprocess launch, and the stdout
/// parse that returns the socket path.
///
/// Kept as a free helper rather than a method on `TerminalEngine` so the
/// daemon-bringup details (binary lookup, env propagation, stdout parse)
/// stay isolated from the engine's lifecycle bookkeeping. Tests can
/// bypass this entirely by registering their own `PaneSurface` directly
/// — daemon bringup is engine-internal.
@MainActor
enum PaneDaemonBringup {
  private static let logger = Logger(
    subsystem: "com.touch-code.runtime",
    category: "runtime.zmx.bringup"
  )

  /// Look up the embedded zmx binary, spawn `zmx serve <paneID>`, parse
  /// its stdout for the daemon socket path, and return a connected
  /// `ZmxClient`. Throws if the binary is missing, the spawn fails, or
  /// the daemon does not print a socket path.
  static func spawnDaemonAndConnect(
    paneID: PaneID,
    workingDirectory: String,
    env: [String: String]
  ) async throws -> ZmxClient {
    let binaryURL = try zmxBinaryURL()
    let cwdURL = URL(fileURLWithPath: workingDirectory)

    // Merge the caller-provided env over the inherited process env so
    // Project-defined env vars (M8) reach the spawned shell while
    // keeping PATH / HOME / TERM defaults intact.
    var mergedEnv = ProcessInfo.processInfo.environment
    for (key, value) in env { mergedEnv[key] = value }

    let runner = FoundationCommandRunner()
    let outcome = await runner.run(
      executable: binaryURL,
      arguments: ["serve", paneID.raw.uuidString, "--cwd", workingDirectory],
      env: mergedEnv,
      cwd: cwdURL,
      // `zmx serve` daemonizes promptly after printing the socket path on
      // stdout, so the parent invocation returns quickly. 10 s leaves
      // headroom for the daemon's PTY setup on a contended box.
      timeout: .seconds(10),
      maxOutputBytes: 64 * 1024
    )

    switch outcome {
    case .exited(let code, let stdoutData, let stderrData, _):
      guard code == 0 else {
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        throw HierarchyError.zmxServeFailed(
          detail: "exit \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
      }
      let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
      let socketPath = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !socketPath.isEmpty else {
        throw HierarchyError.zmxServeNoSocketPath
      }
      logger.debug(
        "spawned zmx serve for pane \(paneID, privacy: .public): socket=\(socketPath, privacy: .public)"
      )
      return try await ZmxClient(paneID: paneID, socketPath: socketPath)

    case .timedOut:
      throw HierarchyError.zmxServeFailed(detail: "timed out waiting for socket path")

    case .spawnFailed(let reason):
      throw HierarchyError.zmxServeFailed(detail: reason)
    }
  }

  /// Resolves the bundled `zmx` binary out of the app bundle's
  /// `Resources/bin/` folder. Tuist's `Embed zmx` build phase
  /// (apps/mac/scripts/embed-zmx.sh) is responsible for putting it
  /// there; absent the resource we cannot proceed.
  private static func zmxBinaryURL() throws -> URL {
    guard
      let url = Bundle.main.url(
        forResource: "zmx", withExtension: nil, subdirectory: "bin"
      )
    else {
      throw HierarchyError.zmxBinaryMissing
    }
    return url
  }
}
