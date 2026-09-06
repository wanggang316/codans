import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Darwin
import Foundation

@main
struct CodansCLI: AsyncParsableCommand {
  static let version = "0.5.1"

  /// The CLI answers to its build channel's name — `codans-dev` in Debug —
  /// so help text, error hints, and the completion scripts generated from
  /// this tree spell the command the user actually has.
  static let commandName = CLIInvocation.commandName

  static let configuration = CommandConfiguration(
    commandName: commandName,
    abstract: "Control Codans from the terminal.",
    discussion: """
      Common examples:
        \(commandName) status
        \(commandName) tree
        \(commandName) pane send 'pwd'
        \(commandName) pane send <pane> 'git status --short'
        \(commandName) pane new --label agent codex
        \(commandName) agent launch --agent claude
        \(commandName) handoff to codex --brief - <<'EOF' … EOF
      """,
    version: "Codans \(CodansCLI.version)",
    subcommands: [
      StatusCommand.self,
      LaunchCommand.self,
      DoctorCommand.self,
      TreeCommand.self,
      ProjectCommand.self,
      WorktreeCommand.self,
      TabCommand.self,
      PaneCommand.self,
      BroadcastCommand.self,
      AgentCommand.self,
      HandoffCommand.self,
    ]
  )

  static func main() async {
    // Belt to SO_NOSIGPIPE's suspenders: ignore SIGPIPE process-wide so
    // any write path (stdout being piped to `head`, a half-closed socket
    // we forgot to flag) returns EPIPE instead of killing the CLI with
    // exit 141 before our error paths can render a message.
    signal(SIGPIPE, SIG_IGN)
    await Self.main(nil)
  }
}

// Global options shared across subcommands via composition — ArgumentParser's
// `@OptionGroup` pattern.
struct GlobalOptions: ParsableArguments {
  @Flag(name: .long, help: "Emit JSON on stdout instead of human-readable text.")
  var json: Bool = false

  @Option(
    name: .long,
    // Built from `BuildChannel` rather than spelled here so the help text
    // (and the completion scripts generated from it) cannot drift from the
    // paths the app actually binds.
    help: ArgumentHelp(
      "Override the socket path (default: $CODANS_SOCKET_PATH → Debug "
        + "\(BuildChannel.development.socketPathTemplate), Release "
        + "\(BuildChannel.release.socketPathTemplate))."
    )
  )
  var socket: String?

  @Option(name: .long, help: "Client-side timeout in seconds for a single unary call.")
  var timeout: Double = 10

  var renderMode: RenderMode {
    json ? .json : .text(useColor: true)
  }

  /// `--socket` wins, then `$CODANS_SOCKET_PATH`, then the build default —
  /// the precedence `SocketDiscovery.resolve` implements, including its
  /// refusal to drive a development pane from the release CLI.
  func resolveSocketPath() throws(SocketDiscovery.ForeignPaneRefusal) -> String {
    try SocketDiscovery.resolve(override: socket)
  }

  var rpcTimeout: Duration {
    .milliseconds(Int64((max(timeout, 0.001) * 1000).rounded(.up)))
  }
}
