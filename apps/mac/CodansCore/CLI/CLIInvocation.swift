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
  public static let commandName: String = {
    #if DEBUG
      return "codans-dev"
    #else
      return "codans"
    #endif
  }()

  /// What to actually write: this build's command name when the installed
  /// symlink resolves to *this* build's binary, and otherwise the absolute
  /// path of the binary the app bundles.
  ///
  /// Existence at the install path is not enough. `/usr/local/bin/codans` is
  /// normally a symlink into `/Applications/Codans.app`, so a locally-built
  /// Release app that wrote the bare name would be handing its work to the
  /// installed app instead of itself — the same class of bug as a Debug build
  /// writing `codans`. Resolving the link and comparing is what makes the
  /// short form safe.
  ///
  /// The absolute-path fallback is also what makes a handoff work at all in a
  /// build whose CLI was never installed, where the name would simply be
  /// "command not found". It is less pretty and always addresses this build.
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
    if isSameFile(installed, bundledBinary, fileManager: fileManager) { return name }
    return ShellQuoting.quoted(bundledBinary.path(percentEncoded: false))
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
