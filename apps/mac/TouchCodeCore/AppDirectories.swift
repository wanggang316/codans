import Foundation

/// Central resolver for touch-code's on-disk persistence roots.
///
/// Debug builds use a `-dev` suffixed directory so a locally-built dev
/// instance running alongside the installed Release never shares its
/// catalog / sessions / settings / `ZMX_DIR` with it. Sharing those caused
/// pane-session crosstalk: both instances loaded the same `catalog.json` and
/// ran `zmx attach <paneID>` against the same `ZMX_DIR`, so a single zmx
/// daemon (one PTY) ended up with two attach clients fanning input and output
/// between the two apps — typing in one app's pane appeared in (and was
/// answered by) the other. Release builds keep the original `touch-code`
/// paths, so the shipped app's on-disk location is unchanged.
///
/// Build type — not bundle identity — is the discriminator on purpose: the
/// `tc` CLI links this module too, and a Debug-built `tc` must resolve the
/// same root as its Debug-built app. `#if DEBUG` gives both the same answer
/// at compile time; reading `Bundle.main` would diverge (the CLI's bundle is
/// the CLI, not the app).
public nonisolated enum AppDirectories {
  /// Base directory name used under both `~/.config` and `~/Library/Caches`.
  /// `touch-code-dev` for Debug builds, `touch-code` for Release.
  public static let name: String = {
    #if DEBUG
      return "touch-code-dev"
    #else
      return "touch-code"
    #endif
  }()

  /// `~/.config/<name>` — user-facing config root holding `catalog.json`,
  /// `sessions.json`, `settings.json`, `notifications.json`, `shortcuts.json`,
  /// `github-snapshots.json`, and the `master-terminal/` subtree.
  public static func configDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
  }

  /// `~/Library/Caches/<name>` — the zmx `ZMX_DIR` (per-pane daemon control
  /// sockets, `snapshots/`, and `logs/`). Falls back to `~/Library/Caches`
  /// when the system cache directory can't be resolved, matching the prior
  /// inline logic in `PaneDaemonBringup` / `ZmxControlClient`.
  public static func cacheDirectory(
    fileManager: FileManager = .default
  ) -> URL {
    let base =
      (try? fileManager.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
      ))
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
    return base.appendingPathComponent(name, isDirectory: true)
  }
}
