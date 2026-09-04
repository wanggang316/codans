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

  /// What to actually write: this build's installed command name when it is
  /// on disk, and otherwise the absolute path of the binary the app bundles.
  ///
  /// The fallback is what makes a handoff work in a build whose CLI was never
  /// installed. Writing the uninstalled name would fail with "command not
  /// found", and writing plain `codans` instead would silently reach the
  /// Release app. An absolute path is less pretty and always right.
  public static func command(
    named name: String = commandName,
    installDirectory: URL = installDirectory,
    bundledBinary: URL?,
    fileManager: FileManager = .default
  ) -> String {
    let installed = installDirectory.appendingPathComponent(name, isDirectory: false)
    if fileManager.isExecutableFile(atPath: installed.path(percentEncoded: false)) {
      return name
    }
    guard let bundledBinary else { return name }
    return ShellQuoting.quoted(bundledBinary.path(percentEncoded: false))
  }
}
