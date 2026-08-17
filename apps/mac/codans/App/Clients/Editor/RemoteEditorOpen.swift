import CodansCore
import Foundation

/// How to open a remote (Server-project) worktree through an editor's own
/// SSH remoting CLI. A local editor opens a local directory URL; a remote
/// worktree instead needs the editor's remote entry point — Zed takes an
/// `ssh://` URL, the VS Code family takes `--remote ssh-remote+<host>`.
/// Editors with no SSH story (Finder, Xcode, JetBrains, terminals, git
/// clients, `$EDITOR`*) return nil and are not offered for remote worktrees.
///
/// *`$EDITOR` is handled elsewhere and needs nothing here: its Pane runs the
/// remote shell already, so the editor launches on the host natively.
nonisolated enum RemoteEditorOpen {
  /// A resolved remote-open command: the editor's bundled CLI (relative to
  /// its `.app` root) plus argv. The CLI hands off to the app and exits.
  struct Invocation: Equatable, Sendable {
    var executableRelativePath: String
    var arguments: [String]
  }

  /// The bundled CLI binary name (under `Contents/Resources/app/bin/`) for
  /// the VS Code family, or nil for any other editor.
  private static let vscodeFamilyCLIName: [EditorID: String] = [
    "vscode": "code",
    "vscodeInsiders": "code-insiders",
    "vscodium": "codium",
    "cursor": "cursor",
    "trae": "trae",
    "traeCN": "trae-cn",
    "windsurf": "windsurf",
    "antigravity": "antigravity",
  ]

  /// Whether `editorID` has any SSH remoting story at all (host-specific
  /// constraints aside). Drives which editors the remote Open menus list.
  static func supportsRemote(_ editorID: EditorID) -> Bool {
    editorID == "zed" || vscodeFamilyCLIName[editorID] != nil
  }

  /// How to open `remotePath` on `host` with this editor, or nil when the
  /// editor cannot express the host.
  static func invocation(
    editorID: EditorID, host: RemoteHost, remotePath: String
  ) -> Invocation? {
    if editorID == "zed" {
      return Invocation(
        executableRelativePath: "Contents/MacOS/cli",
        arguments: [sshURL(host: host, remotePath: remotePath)]
      )
    }
    guard let cliName = vscodeFamilyCLIName[editorID] else { return nil }
    // The VS Code family parses `ssh-remote+host:2222` as a literal hostname —
    // there is no inline port syntax — so a non-default port is inexpressible
    // on the command line and must live in ~/.ssh/config instead.
    guard !host.hasNonDefaultPort else { return nil }
    return Invocation(
      executableRelativePath: "Contents/Resources/app/bin/\(cliName)",
      arguments: ["--remote", "ssh-remote+\(host.sshDestination)", remotePath]
    )
  }

  /// A human-facing reason this editor is disabled for `host`, or nil when
  /// it can open (a reason structurally implies a disabled menu row).
  /// Non-nil only for the VS Code family on a non-default port.
  static func disabledReason(
    editorID: EditorID, host: RemoteHost, displayName: String
  ) -> String? {
    guard supportsRemote(editorID),
      invocation(editorID: editorID, host: host, remotePath: "/") == nil
    else { return nil }
    return "Opening \(displayName) over SSH needs the port in ~/.ssh/config"
  }

  /// `ssh://[user@]host[:port]<path>` for Zed's SSH remoting CLI. The path is
  /// normalized to a leading `/` so it cannot fuse with the authority, then
  /// percent-encoded for URI validity (spaces, non-ASCII); `.urlPathAllowed`
  /// keeps the `/` separators intact.
  static func sshURL(host: RemoteHost, remotePath: String) -> String {
    let normalized = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
    let encoded =
      normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
    return "ssh://\(host.authority)\(encoded)"
  }
}
