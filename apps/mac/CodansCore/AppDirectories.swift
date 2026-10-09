import Foundation

/// Central resolver for codans's on-disk persistence roots.
///
/// Debug builds use a `-dev` suffixed directory so a locally-built dev
/// instance running alongside the installed Release never shares its
/// catalog / sessions / settings / `ZMX_DIR` with it. Sharing those caused
/// pane-session crosstalk: both instances loaded the same `catalog.json` and
/// ran `zmx attach <paneID>` against the same `ZMX_DIR`, so a single zmx
/// daemon (one PTY) ended up with two attach clients fanning input and output
/// between the two apps — typing in one app's pane appeared in (and was
/// answered by) the other. Release builds keep the original `codans`
/// paths, so the shipped app's on-disk location is unchanged.
///
/// The suffix comes from `BuildChannel`, which is where the build-type
/// decision is made and why.
public nonisolated enum AppDirectories {
  /// Channel slug: `codans-dev` for Debug builds, `codans` for Release. Names
  /// the cache root and the legacy `~/.config/<name>` directory.
  public static let name: String = BuildChannel.current.slug

  /// `~/.<name>` — the channel's root: `~/.codans` for Release,
  /// `~/.codans-dev` for Debug. Config and state live under it, so the two
  /// channels are isolated at the top level.
  public static func channelDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home.appendingPathComponent(".\(name)", isDirectory: true)
  }

  /// `~/.codans[-dev]/config` — files the user may edit by hand:
  /// `settings.json` and `shortcuts.json`.
  public static func configDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    override: String? = ProcessInfo.processInfo.environment[CodansEnvironment.Key.configDirectory.rawValue]
  ) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return channelDirectory(home: home).appendingPathComponent("config", isDirectory: true)
  }

  /// `~/.codans[-dev]/state` — files only the app writes: `catalog.json`,
  /// `sessions.json`, `notifications.json`, the remote-host sidecars,
  /// `project-icons/`, `agent-homes/`, and `backups/`.
  ///
  /// `$CODANS_CONFIG_DIR` alone still relocates *every* store (config and
  /// state land flat in that one directory), so an isolated smoke run that
  /// predates the config/state split keeps all its data private.
  /// `$CODANS_STATE_DIR` relocates state on its own and wins over it.
  public static func stateDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    override: String? = ProcessInfo.processInfo.environment[CodansEnvironment.Key.stateDirectory.rawValue],
    configOverride: String? = ProcessInfo.processInfo.environment[CodansEnvironment.Key.configDirectory.rawValue]
  ) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let configOverride, !configOverride.isEmpty {
      return URL(fileURLWithPath: configOverride, isDirectory: true)
    }
    return channelDirectory(home: home).appendingPathComponent("state", isDirectory: true)
  }

  /// `~/.config/<name>` — where every store lived before the config/state
  /// split. Read only by `LegacyConfigMigrator`.
  public static func legacyConfigDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
  }

  /// `~/.codans` — the user-level root every *new* persistent directory
  /// goes under (`repos/` for worktrees already lives here). The
  /// `~/.config/<name>` config root is legacy and is not extended further.
  /// Not channel-suffixed: what lives here is user content, not instance
  /// state, and a Debug build should see the same workflows as Release.
  public static func userDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home.appendingPathComponent(".codans", isDirectory: true)
  }

  /// `~/.codans/workflows` — user-scoped `*.workflow.yaml` definitions.
  /// `$CODANS_WORKFLOWS_DIR` relocates it for isolated test instances.
  public static func workflowsDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    override: String? = ProcessInfo.processInfo.environment[CodansEnvironment.Key.workflowsDirectory.rawValue]
  ) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return userDirectory(home: home).appendingPathComponent("workflows", isDirectory: true)
  }

  /// `~/Library/Caches/<name>` — the zmx `ZMX_DIR` (per-pane daemon control
  /// sockets, `snapshots/`, and `logs/`). Falls back to `~/Library/Caches`
  /// when the system cache directory can't be resolved, matching the prior
  /// inline logic in `PaneDaemonBringup` / `ZmxControlClient`.
  public static func cacheDirectory(
    fileManager: FileManager = .default,
    override: String? = ProcessInfo.processInfo.environment[CodansEnvironment.Key.cacheDirectory.rawValue]
  ) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base =
      (try? fileManager.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
      ))
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
    return base.appendingPathComponent(name, isDirectory: true)
  }
}
