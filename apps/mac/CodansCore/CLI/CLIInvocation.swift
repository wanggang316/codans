import Foundation

/// How the app spells its own CLI when it writes a command a human or an
/// agent will run.
public nonisolated enum CLIInvocation {
  /// Directory the CLI installs into.
  public static let installDirectory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

  /// The command name this build's CLI installs as: `codans-dev` for Debug,
  /// `codans` for Release. Kept in lockstep with `CLIInstallerClient.Paths`,
  /// which links against this.
  ///
  /// A Debug build must never write plain `codans`. That name belongs to the
  /// installed Release build, and its CLI resolves the Release socket — so a
  /// command typed into a Debug app's pane would be answered by a different
  /// app entirely.
  public static let commandName: String = BuildChannel.current.slug

  /// What to actually write for a command that will run inside one of this
  /// app's panes: the command name whenever that name reaches *this* build's
  /// binary there, otherwise the absolute path of the binary the app bundles.
  ///
  /// The name reaches us in two cases. Either nothing is installed under it,
  /// so the only candidate is the bundle's own `bin/` — which every pane has
  /// on PATH (`PaneEnvironment`), and which no shell reordering can displace
  /// when there is no competitor. Or the installed symlink resolves to our
  /// bundled binary. Existence alone is not enough: `/usr/local/bin/codans`
  /// normally links into `/Applications/Codans.app`, so a locally-built
  /// Release app that wrote the bare name would hand its work to the
  /// installed app instead of itself. Only the install directory is checked;
  /// a same-named binary elsewhere on the user's PATH is not detected.
  ///
  /// With no bundled binary to compare against there is nothing better to
  /// offer, so the bare name stands.
  public static func command(
    named name: String = commandName,
    installDirectory: URL = installDirectory,
    bundledBinary: URL?,
    fileManager: FileManager = .default
  ) -> String {
    guard let bundledBinary else { return name }
    let installed = installDirectory.appendingPathComponent(name, isDirectory: false)
    guard entryExists(installed, fileManager: fileManager) else { return name }
    if isSameFile(installed, bundledBinary, fileManager: fileManager) { return name }
    return ShellQuoting.quoted(bundledBinary.path(percentEncoded: false))
  }

  /// True for any directory entry at `url`, including a dangling symlink,
  /// which `fileExists` reports as absent but which still shadows the name.
  private static func entryExists(_ url: URL, fileManager: FileManager) -> Bool {
    (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
  }

  /// Symlink- and prefix-resolved identity test. `/usr/local/bin/codans` is a
  /// link, and a temporary directory reaches the same file through both
  /// `/var` and `/private/var`, so the raw paths of one binary routinely
  /// differ.
  private static func isSameFile(
    _ lhs: URL,
    _ rhs: URL,
    fileManager: FileManager
  ) -> Bool {
    let left = lhs.resolvingSymlinksInPath().standardizedFileURL
    guard fileManager.isExecutableFile(atPath: left.path(percentEncoded: false)) else {
      return false
    }
    return left == rhs.resolvingSymlinksInPath().standardizedFileURL
  }
}
