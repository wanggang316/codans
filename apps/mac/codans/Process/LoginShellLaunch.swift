import Darwin
import Foundation

/// What `Foundation.Process` receives for one launch.
nonisolated struct ProcessLaunch: Equatable, Sendable {
  var executable: URL
  var arguments: [String]
  var environment: [String: String]
  var currentDirectory: URL
}

/// The shell that wraps a background command. Only shells whose rc file and
/// argument handling are known are used; any other login shell falls back to
/// `/bin/zsh`. Terminals are not affected: Ghostty starts the user's real shell.
nonisolated enum LoginShell: Equatable, Sendable {
  case zsh(URL)
  case bash(URL)
  case fish(URL)

  static let fallback = LoginShell.zsh(URL(fileURLWithPath: "/bin/zsh"))

  /// Maps a login shell path (`pw_shell`) to a supported shell.
  init(path: String?) {
    guard let path, path.hasPrefix("/") else {
      self = Self.fallback
      return
    }
    let url = URL(fileURLWithPath: path)
    switch url.lastPathComponent {
    case "zsh": self = .zsh(url)
    case "bash": self = .bash(url)
    case "fish": self = .fish(url)
    default: self = Self.fallback
    }
  }

  /// The user's login shell from the user database. Read on every launch, so a
  /// `chsh` applies to the next command without an app restart.
  static func current() -> LoginShell {
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
      return fallback
    }
    return LoginShell(path: String(cString: shell))
  }

  var url: URL {
    switch self {
    case .zsh(let url), .bash(let url), .fish(let url): url
    }
  }
}

/// Runs a background command (git, the bundled `wt`, `gh`, `glab`) through the
/// user's login shell, so it and everything it starts (a credential helper, an
/// `ext::` command) see the same `PATH` as a command typed in a codans terminal,
/// also when launchd started the app with `/usr/bin:/bin:/usr/sbin:/sbin`.
///
/// One launch is:
///
///     <shell> -l -c '<script>' -- [<cwd>] KEY=VALUE… <executable> <arguments…>
///
/// The script saves the positional parameters and clears them, sources the rc
/// file with its output sent to `/dev/null`, enters `<cwd>` with `builtin cd`
/// (exit 125 on failure), and then runs
/// `exec /usr/bin/env -i PATH=<login PATH> KEY=VALUE… <executable> <arguments…>`.
///
/// After the rc ran, the command gets exactly the caller's environment, with
/// only `PATH` taken from the login shell. This keeps every caller's environment
/// contract (`GitProcessEnv`'s allowlist and stripped `GIT_*` keys, `LC_ALL`,
/// `GIT_TERMINAL_PROMPT=0`, the `gh` / `glab` token stripping) true even when the
/// rc exports a key the caller removed. `exec` keeps one process, so the
/// runner's timeout and cancel kill the real command. See
/// `docs/design-docs/environment.md`.
nonisolated enum LoginShellLaunch {
  /// Exit status when the working directory cannot be entered: the command
  /// never started. Git itself does not use it.
  static let directoryFailureStatus: Int32 = 125

  enum Failure: Error, Equatable, Sendable {
    case executableMissing(String)
    /// `env` reads an operand with `=` as an assignment, not as the command.
    case unsupportedExecutablePath(String)

    var reason: String {
      switch self {
      case .executableMissing(let path): "binary not found: \(path)"
      case .unsupportedExecutablePath(let path): "executable path contains '=': \(path)"
      }
    }
  }

  /// Checks the executable, then builds the launch with the current login shell.
  static func prepare(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL?,
    shell: LoginShell = .current()
  ) throws(Failure) -> ProcessLaunch {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw .executableMissing(executable.path)
    }
    return try build(executable: executable, arguments: arguments, env: env, cwd: cwd, shell: shell)
  }

  /// Pure builder. `env` is the environment the command must get; the shell
  /// itself also starts with it, so `HOME` locates the rc file.
  static func build(
    executable: URL,
    arguments: [String],
    env: [String: String],
    cwd: URL?,
    shell: LoginShell
  ) throws(Failure) -> ProcessLaunch {
    guard !executable.path.contains("=") else {
      throw .unsupportedExecutablePath(executable.path)
    }
    var positional: [String] = []
    if let cwd { positional.append(cwd.path) }
    positional += env.keys
      .filter { $0 != "PATH" && !$0.isEmpty && !$0.contains("=") }
      .sorted()
      .map { "\($0)=\(env[$0] ?? "")" }
    positional.append(executable.path)
    positional += arguments
    return ProcessLaunch(
      executable: shell.url,
      arguments: ["-l", "-c", script(for: shell, changesDirectory: cwd != nil), "--"] + positional,
      environment: env,
      // The shell enters the real directory itself, after the rc; a missing
      // directory must reach the script (exit 125), not fail the spawn.
      currentDirectory: URL(fileURLWithPath: "/", isDirectory: true)
    )
  }

  /// One line, so the shell parses all of it before the rc runs: aliases the
  /// rc defines cannot change it.
  static func script(for shell: LoginShell, changesDirectory: Bool) -> String {
    switch shell {
    case .zsh:
      posixScript(rc: "\"${ZDOTDIR:-$HOME}/.zshrc\"", changesDirectory: changesDirectory)
    case .bash:
      posixScript(rc: "\"$HOME/.bashrc\"", changesDirectory: changesDirectory)
    case .fish:
      // fish loads `config.fish` and `conf.d` itself for every `-c`, before
      // this script runs and without access to `$argv`; sourcing it again
      // would run it twice. Its output cannot be redirected from here.
      [
        changesDirectory
          ? "set -g __codans_dir $argv[1]; set -g __codans_argv $argv[2..-1]"
          : "set -g __codans_argv $argv",
        "set -e argv",
        changesDirectory
          ? "builtin cd $__codans_dir >/dev/null 2>&1; or exit \(directoryFailureStatus)" : nil,
        "exec /usr/bin/env -i \"PATH=$PATH\" $__codans_argv",
      ].compactMap(\.self).joined(separator: "; ")
    }
  }

  private static func posixScript(rc: String, changesDirectory: Bool) -> String {
    [
      changesDirectory ? "__codans_dir=$1; shift" : nil,
      "__codans_argv=(\"$@\")",
      "set --",
      "if [ -r \(rc) ]; then . \(rc) </dev/null >/dev/null 2>&1; fi",
      changesDirectory
        ? "builtin cd -- \"$__codans_dir\" >/dev/null 2>&1 || exit \(directoryFailureStatus)" : nil,
      "exec /usr/bin/env -i \"PATH=$PATH\" \"${__codans_argv[@]}\"",
    ].compactMap(\.self).joined(separator: "; ")
  }
}
