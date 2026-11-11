import Foundation

/// Chooses how a local `git` invocation starts (see
/// `docs/design-docs/environment.md`). A command that reaches a remote may
/// start credential, LFS, or ssh helpers from the user's `PATH`, so it runs
/// through the login shell. Every other git command runs often (status and
/// diff refreshes) and starts directly, with one login-shell retry when it
/// reports a missing command.
nonisolated enum GitLaunch {
  /// Subcommands that talk to a remote.
  static let remoteSubcommands: Set<String> = ["clone", "fetch", "push", "pull", "ls-remote"]
  /// `git remote <verb>` verbs that contact the remote (`show` unless `-n`).
  static let remoteVerbs: Set<String> = ["show", "update", "prune"]

  static func mode(for arguments: [String]) -> CommandLaunch {
    reachesRemote(arguments) ? .loginShell : .directThenLoginShell
  }

  static func reachesRemote(_ arguments: [String]) -> Bool {
    guard let index = subcommandIndex(arguments) else { return false }
    let subcommand = arguments[index]
    if remoteSubcommands.contains(subcommand) { return true }
    guard subcommand == "remote" else { return false }
    let rest = arguments[(index + 1)...]
    guard let verb = rest.first(where: { !$0.hasPrefix("-") }), remoteVerbs.contains(verb) else { return false }
    return !(verb == "show" && rest.contains("-n"))
  }

  /// Index of the first argument after git's global options.
  private static func subcommandIndex(_ arguments: [String]) -> Int? {
    // Global options that take their value as the next argument.
    let withValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if withValue.contains(argument) {
        index += 2
      } else if argument.hasPrefix("-") {
        index += 1
      } else {
        return index
      }
    }
    return nil
  }
}
