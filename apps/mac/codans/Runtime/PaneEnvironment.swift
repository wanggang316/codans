import CodansCore
import Foundation

/// Assembles the environment a pane's shell starts with. Every surface —
/// worktree panes and the Master Terminal alike — goes through here, so the
/// set of variables codans injects is decided once and cannot diverge
/// between spawn paths. The names come from `CodansEnvironment.Key`.
///
/// Two stages, because the callers know different things:
///
/// 1. `processBase` needs only what the *app* knows: the inherited process
///    environment, a project's own `envVars`, and the always-wins product
///    keys. `HierarchyManager.resolvedEnv` is this with the project's
///    overrides looked up from Settings.
/// 2. `forSurface` needs the *pane*: its id and the zmx socket directory.
///    `TerminalEngine.ensureSurface` applies it last, after the worktree
///    built-ins.
nonisolated enum PaneEnvironment {
  /// `CFBundleShortVersionString` of the running app; nil under a bare
  /// `xctest` host, in which case the version key is simply omitted.
  static let appMarketingVersion: String? =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

  /// The CLI this app bundles, located once. `nil` only when no binary can
  /// be found at all (a bare test host), in which case panes get no `PATH`
  /// entry and no `CODANS_CLI`.
  static let bundledCLI: URL? = try? CLIBundleLocator.locateBinary()

  /// Stage 1. Inherit, strip the terminal-describing keys so libghostty's
  /// own PTY-time values win, layer the caller's overrides, then write the
  /// keys that must always win — the socket, the product marker, and this
  /// app's CLI — last, so an override of the same name can never shadow
  /// them.
  ///
  /// The CLI is made reachable two ways. Its directory goes first on `PATH`,
  /// so a bare `codans` typed or scripted inside the pane is this app's
  /// binary; that is what keeps a Debug pane off the installed Release CLI,
  /// which is older and dials the Release socket. `CODANS_CLI` carries the
  /// absolute path for the case a shell rc rebuilds `PATH` and drops the
  /// entry. Both are written after the project's overrides on purpose — a
  /// project that sets its own `PATH` still gets this app's CLI in front.
  static func processBase(
    inheriting inherited: [String: String] = ProcessInfo.processInfo.environment,
    overrides: [String: String],
    socketPath: String,
    cliBinary: URL? = bundledCLI,
    marketingVersion: String? = appMarketingVersion
  ) -> [String: String] {
    var env = inherited
    for key in CodansEnvironment.inheritedTerminalKeysToStrip {
      env.removeValue(forKey: key)
    }
    for (key, value) in overrides {
      env[key] = value
    }
    env[CodansEnvironment.Key.socketPath.rawValue] = socketPath
    if let cliBinary {
      env[CodansEnvironment.Key.cli.rawValue] = cliBinary.path
      env["PATH"] = prefixingPath(env["PATH"], with: cliBinary.deletingLastPathComponent().path)
    }
    env[TermProgramEnv.programKey] = TermProgramEnv.program
    if let marketingVersion {
      env[TermProgramEnv.versionKey] = marketingVersion
    }
    return env
  }

  /// `directory` first, then the existing entries with any earlier copy of
  /// `directory` removed — so re-spawning a pane from inside a pane does not
  /// stack the entry, and an installed copy later on `PATH` never wins.
  static func prefixingPath(_ path: String?, with directory: String) -> String {
    let rest = (path ?? "")
      .split(separator: ":", omittingEmptySubsequences: true)
      .map(String.init)
      .filter { $0 != directory }
    return ([directory] + rest).joined(separator: ":")
  }

  /// Stage 2. Adds what only the pane knows.
  ///
  /// - `ZMX_DIR` is pinned so the daemon socket lands where the control
  ///   client and the reaper look; the caller has already created it.
  /// - `ZMX_SESSION` is cleared. An app launched from inside a zmx pane
  ///   inherits the parent's session name, and `zmx attach` reads a set
  ///   value as "switch to that session from within it" — which fails,
  ///   because the parent lives in another `ZMX_DIR`. That surfaced as a
  ///   tab that flashed and vanished.
  /// - `CODANS_PANE_ID` is the pane's own id, safe to bake in because it
  ///   never changes; the CLI's `current` reads it before asking the server.
  static func forSurface(
    _ base: [String: String],
    paneID: PaneID,
    zmxDirectory: URL
  ) -> [String: String] {
    var env = base
    env[CodansEnvironment.Key.zmxDirectory.rawValue] = zmxDirectory.path
    env[CodansEnvironment.Key.zmxSession.rawValue] = ""
    env[CodansEnvironment.Key.paneID.rawValue] = paneID.raw.uuidString
    return env
  }
}
