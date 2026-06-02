import Foundation
import TouchCodeCore

/// Builds the shell command string handed to libghostty's exec backend as
/// `ghostty_surface_config_s.command`. The pane's shell runs *inside* a
/// `zmx attach <session>` client so the underlying process survives app
/// quit: libghostty owns and sizes a normal local PTY (its exec backend
/// only forks the child once a real post-layout size is known), and the
/// `zmx attach` client proxies that PTY's bytes to/from the per-Pane
/// daemon. On next launch the same session name re-attaches to the live
/// daemon (zmx `attach` upserts: it reuses a running session or creates a
/// fresh one).
///
/// libghostty wraps `config.command` as `/bin/sh -c "<value>"` on macOS,
/// so the value is a single shell string. Any user command runs *under*
/// the attached session via a trailing `/bin/sh -c <command>` so it shares
/// the same resume semantics as the default shell.
nonisolated enum ZmxAttachCommand {
  /// The zmx session name for a Pane. zmx names its control socket
  /// `<ZMX_DIR>/<ZMX_SESSION_PREFIX><session>`; touch-code sets no prefix
  /// and uses the PaneID's UUID string, so the name is stable across
  /// launches (the property that makes re-attach work).
  static func session(for paneID: PaneID) -> String {
    paneID.raw.uuidString
  }

  /// Compose `<zmx> attach <session> [/bin/sh -c <userCommand>]`.
  /// `userCommand` is the Pane's `initialCommand` (e.g. a worktree setup
  /// script); when nil/empty the attached session runs the login shell.
  static func build(zmxPath: String, session: String, userCommand: String?) -> String {
    let attach = "\(shellQuote(zmxPath)) attach \(shellQuote(session))"
    guard let trimmed = userCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return attach
    }
    return "\(attach) /bin/sh -c \(shellQuote(trimmed))"
  }

  /// Single-quote a value for `/bin/sh`, escaping embedded single quotes
  /// via the standard `'\''` dance so paths with spaces or shell
  /// metacharacters survive the `/bin/sh -c` wrapping intact.
  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
