import ArgumentParser
import Darwin
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

@main
struct TouchCodeCLI: AsyncParsableCommand {
  static let version = "0.4.2"

  static let configuration = CommandConfiguration(
    commandName: "tc",
    abstract: "Control TouchCode from the terminal.",
    discussion: """
      Common examples:
        tc status
        tc tree
        tc pane send 'pwd'
        tc pane send <pane> 'git status --short'
        tc pane new --label agent codex
      """,
    version: "TouchCode \(TouchCodeCLI.version)",
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
    help:
      "Override the socket path (default: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock)."
  )
  var socket: String?

  @Option(name: .long, help: "Client-side timeout in seconds for a single unary call.")
  var timeout: Double = 10

  var renderMode: RenderMode {
    json ? .json : .text(useColor: true)
  }

  var resolvedSocketPath: String {
    SocketDiscovery.resolve(override: socket)
  }

  var rpcTimeout: Duration {
    .milliseconds(Int64((max(timeout, 0.001) * 1000).rounded(.up)))
  }
}
