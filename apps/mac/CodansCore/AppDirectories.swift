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

  /// `~/.codans` — the user-level root shared by both channels. Channel
  /// isolation happens one level down (`config` vs `config-dev`, …).
  public static func userDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home.appendingPathComponent(".codans", isDirectory: true)
  }

  /// `~/.codans/config[-dev]` — files the user may edit by hand:
  /// `settings.json`, `shortcuts.json`, and the `master-terminal/` subtree.
  public static func configDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    override: String? = ProcessInfo.processInfo.environment[CodansEnvironment.Key.configDirectory.rawValue]
  ) -> URL {
    if let override, !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return userDirectory(home: home)
      .appendingPathComponent(channelScoped("config"), isDirectory: true)
  }

  /// `~/.codans/state[-dev]` — files only the app writes: `catalog.json`,
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
    return userDirectory(home: home)
      .appendingPathComponent(channelScoped("state"), isDirectory: true)
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

  /// `base` for Release, `base-dev` for Debug.
  static func channelScoped(_ base: String, channel: BuildChannel = .current) -> String {
    switch channel {
    case .release: return base
    case .development: return "\(base)-dev"
    }
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
