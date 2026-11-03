import Foundation

/// Asks `ssh -G <host>` which host name an SSH host connects to, so an alias from
/// `~/.ssh/config` (`Host github-work` → `HostName github.com`) can be matched to a host
/// that a Code Host CLI is logged in to. `ssh -G` only prints the resolved configuration;
/// it opens no connection.
nonisolated struct SSHHostName: Sendable {
  static let executable = URL(fileURLWithPath: SSHCommand.sshExecutablePath)
  static let timeout: Duration = .seconds(5)

  let runner: any CommandRunner

  init(runner: any CommandRunner = FoundationCommandRunner()) {
    self.runner = runner
  }

  /// The `hostname` that ssh uses for `host`, or `nil` when `host` is not a plain host
  /// name or ssh fails. A host with no `Host` block resolves to itself.
  func resolve(_ host: String) async -> String? {
    guard Self.isPlainHost(host) else { return nil }
    let outcome = await runner.run(
      executable: Self.executable,
      arguments: ["-G", "--", host],
      env: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LC_ALL": "C"],
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: Self.timeout,
      maxOutputBytes: 256 * 1024
    )
    guard case .exited(0, let stdout, _, _) = outcome else { return nil }
    guard let text = String(bytes: stdout, encoding: .utf8) else { return nil }
    let lines = text.split(separator: "\n")
    for line in lines where line.hasPrefix("hostname ") {
      let name = line.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? nil : name
    }
    return nil
  }

  /// Letters, digits, `.`, `-`, `_`, not starting with `-`: no option or shell syntax can
  /// reach ssh through the argv.
  static func isPlainHost(_ host: String) -> Bool {
    guard let first = host.first, first != "-" else { return false }
    return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
  }
}
