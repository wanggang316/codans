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

  /// Canonical zmx `ZMX_DIR`. The daemon places its control socket here
  /// and writes snapshots into `<ZMX_DIR>/snapshots/<paneID>.snap`. We
  /// pin this to `~/Library/Caches/touch-code` so the snapshot path the
  /// daemon produces lines up byte-for-byte with `ZmxClient.snapshotURL`
  /// and `SessionReaper`'s launch-time scan — without a pin, zmx falls
  /// back to `$TMPDIR/zmx-<uid>` (or `$XDG_RUNTIME_DIR/zmx`) which would
  /// scatter snapshots somewhere the reaper has no reason to look.
  static func canonicalSocketDirectory() -> URL {
    let fm = FileManager.default
    let base =
      (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
    return base.appendingPathComponent("touch-code", isDirectory: true)
  }

  /// Directory the daemon writes `<paneID>.snap` into when `.Snapshot`
  /// fires. Mirrors `ZmxClient.defaultSnapshotDirectory()` so a snapshot
  /// produced by the daemon at quit-time is the same file the reaper
  /// finds at launch-time. Kept here (rather than re-derived in
  /// `SessionReaper`) so the canonical path has one owner.
  static func canonicalSnapshotDirectory() -> URL {
    canonicalSocketDirectory().appendingPathComponent("snapshots", isDirectory: true)
  }

  /// Look up the embedded zmx binary, spawn `zmx serve <paneID>`, parse
  /// its stdout for the daemon socket path, and return a connected
  /// `ZmxClient`. Throws if the binary is missing, the spawn fails, or
  /// the daemon does not print a socket path.
  static func spawnDaemonAndConnect(
    paneID: PaneID,
    workingDirectory: String,
    env: [String: String]
  ) async throws -> ZmxClient {
    return try await spawn(
      paneID: paneID,
      workingDirectory: workingDirectory,
      env: env,
      extraArguments: []
    )
  }

  /// Spawn `zmx serve <paneID> --cwd <cwd> --restore-from <snap>` so the
  /// daemon pre-fills its VT mirror with the captured buffer before the
  /// shell starts. The shell itself is a fresh fork+exec — only the
  /// visible terminal state is reproduced. The snapshot file is
  /// consumed on success: a successful restore deletes the `.snap` so a
  /// later launch does not re-replay stale state.
  static func restore(
    paneID: PaneID,
    workingDirectory: String,
    snapshotURL: URL,
    env: [String: String] = [:]
  ) async throws -> ZmxClient {
    let client = try await spawn(
      paneID: paneID,
      workingDirectory: workingDirectory,
      env: env,
      extraArguments: ["--restore-from", snapshotURL.path]
    )
    // Single-use restore — drop the file once the daemon has it. Best
    // effort: if the unlink fails, the next launch will replay the same
    // bytes into a fresh daemon, which is recoverable (the user sees
    // their buffer again, just like a re-quit) rather than catastrophic.
    do {
      try FileManager.default.removeItem(at: snapshotURL)
    } catch {
      logger.warning(
        "failed to remove consumed snapshot \(snapshotURL.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
    return client
  }

  /// Common spawn helper. `extraArguments` is appended after the
  /// `--cwd <path>` pair so callers can opt in to `--restore-from <file>`
  /// without reimplementing the stdout-parse / ZmxClient handshake.
  private static func spawn(
    paneID: PaneID,
    workingDirectory: String,
    env: [String: String],
    extraArguments: [String]
  ) async throws -> ZmxClient {
    let binaryURL = try zmxBinaryURL()
    let cwdURL = URL(fileURLWithPath: workingDirectory)

    // Merge the caller-provided env over the inherited process env so
    // Project-defined env vars (M8) reach the spawned shell while keeping
    // PATH / HOME intact. Terminal-describing vars are re-injected just
    // below (see the `TERM` block). `ZMX_DIR` is pinned last so callers
    // cannot accidentally redirect the daemon out of touch-code's canonical
    // cache directory — snapshot path alignment depends on this being
    // authoritative.
    var mergedEnv = ProcessInfo.processInfo.environment
    for (key, value) in env { mergedEnv[key] = value }
    // libghostty's External backend hands the PTY to the zmx daemon, so the
    // `TERM` injection ghostty's own Exec backend performs (upstream
    // termio/Exec.zig — `xterm-ghostty` + `COLORTERM=truecolor`) never runs
    // for daemon-backed panes. Without it the daemon shell inherits whatever
    // `TERM` the app process carries; when touch-code is launched from a
    // non-interactive parent (Xcode's debugserver, `make` → `open`) that is
    // `TERM=dumb`, which disables starship and breaks every TUI. Re-inject
    // the values here so the spawned shell sees a capable terminal. The
    // bundled `xterm-ghostty` entry resolves because `GhosttyBootstrap`
    // exports `TERMINFO_DIRS` at launch; fall back to `xterm-256color` only
    // if that export is somehow missing.
    mergedEnv.removeValue(forKey: "TERMCAP")
    let ghosttyTerminfoAvailable =
      mergedEnv["TERMINFO_DIRS"] != nil || mergedEnv["TERMINFO"] != nil
    mergedEnv["TERM"] = ghosttyTerminfoAvailable ? "xterm-ghostty" : "xterm-256color"
    mergedEnv["COLORTERM"] = "truecolor"
    mergedEnv["TERM_PROGRAM"] = "ghostty"
    let zmxDir = canonicalSocketDirectory()
    mergedEnv["ZMX_DIR"] = zmxDir.path
    // zmx's mkdir helper is non-recursive (`mkdirat`), so the parent
    // chain must already exist before the daemon attempts to create
    // the socket file. `~/Library/Caches` is always present on macOS;
    // `touch-code/` underneath it may not be on first launch.
    try? FileManager.default.createDirectory(
      at: zmxDir,
      withIntermediateDirectories: true
    )

    var arguments = ["serve", paneID.raw.uuidString, "--cwd", workingDirectory]
    arguments.append(contentsOf: extraArguments)

    let runner = FoundationCommandRunner()
    let outcome = await runner.run(
      executable: binaryURL,
      arguments: arguments,
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
      // `zmx serve` prints two newline-terminated lines on stdout: the
      // daemon's Unix control-socket path, then the daemon process PID
      // (or `0` when ensureSession attached to a pre-existing daemon
      // and did not fork a new one). Older daemon binaries print only
      // the socket path; treat the missing PID line as `0` rather than
      // failing — the rest of the spawn handshake still works, and the
      // session catalog records `0` for "unknown".
      let lines = stdout.split(whereSeparator: \.isNewline)
      let socketPath = lines.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
      guard !socketPath.isEmpty else {
        throw HierarchyError.zmxServeNoSocketPath
      }
      let daemonPID: Int32 =
        lines.dropFirst().first
        .flatMap { Int32(String($0).trimmingCharacters(in: .whitespaces)) } ?? 0
      // pid==0 means `zmx serve` reused a pre-existing daemon (via
      // `ensureSession`) rather than forking a new one — the daemon is
      // already in `has_had_client = true` state and the next `.init`
      // we send will trigger the serialize-and-replay branch. Logging
      // the reuse flag here lets us diagnose whether the resume path
      // actually walked through daemon reuse vs. a fresh spawn.
      let isReused = (daemonPID == 0)
      logger.info(
        "spawn returned: pane=\(paneID, privacy: .public) socketPath=\(socketPath, privacy: .public) daemonPID=\(daemonPID, privacy: .public) isReused=\(isReused, privacy: .public)"
      )
      return try await ZmxClient(
        paneID: paneID,
        socketPath: socketPath,
        daemonPID: daemonPID,
        cwd: workingDirectory,
        command: [],
        zmxVersion: "",
        createdAt: Date()
      )

    case .timedOut:
      throw HierarchyError.zmxServeFailed(detail: "timed out waiting for socket path")

    case .spawnFailed(let reason):
      throw HierarchyError.zmxServeFailed(detail: reason)
    }
  }

  /// Attach to a daemon that survived the previous touch-code process.
  /// The caller (`SessionReaper`) has already verified the socket path
  /// answers `connect(2)`, so this is a thin wrapper around `ZmxClient`'s
  /// existing constructor that threads through the catalog-recorded
  /// metadata (PID, cwd, command, version, createdAt) and stamps a fresh
  /// `lastAttachedAt`.
  ///
  /// Replay of the daemon's screen state is handled inside `attach`: the
  /// daemon serializes its terminal on every `.Init` after the first
  /// (its `has_had_client` flag latches `true` on the leader's first
  /// resize, before our reattach), so a touch-code restart receives the
  /// snapshot frame as part of the standard handshake.
  static func reattach(
    paneID: PaneID,
    session: Session
  ) async throws -> ZmxClient {
    let client = try await ZmxClient(
      paneID: paneID,
      socketPath: session.socketPath,
      daemonPID: session.pid,
      cwd: session.cwd,
      command: session.command,
      zmxVersion: session.zmxVersion,
      createdAt: session.createdAt
    )
    logger.debug(
      "reattached to zmx daemon for pane \(paneID, privacy: .public): socket=\(session.socketPath, privacy: .public) pid=\(session.pid, privacy: .public)"
    )
    return client
  }

  /// Resolves the bundled `zmx` binary out of the app bundle's
  /// `Resources/bin/` folder. Tuist's `Embed zmx` build phase
  /// (apps/mac/scripts/embed-zmx.sh) is responsible for putting it
  /// there; absent the resource we cannot proceed.
  static func zmxBinaryURL() throws -> URL {
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
