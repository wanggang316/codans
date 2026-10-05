import Foundation
import CodansCore

/// Builds how a pane's surface launches under zmx, so the underlying
/// process survives app quit: libghostty owns and sizes a normal local PTY
/// (its exec backend only forks the child once a real post-layout size is
/// known), and the `zmx attach` client proxies that PTY's bytes to/from the
/// per-Pane daemon. On next launch the same session name re-attaches to the
/// live daemon (zmx `attach` upserts: it reuses a running session or creates
/// a fresh one).
///
/// Two shapes, see docs/design-docs/pane-shell-integration.md:
///
/// - `wrapperArgv` for an interactive pane: libghostty resolves the user's
///   shell, injects its shell integration and applies the macOS login(1)
///   wrapping, then prepends this argv, so `zmx attach` runs that resolved
///   command as the new session's program.
/// - `build` for a pane that runs a fixed command (a Server project's SSH
///   loop): one shell string libghostty wraps as `/bin/sh -c "<value>"`.
nonisolated enum ZmxAttachCommand {
  /// The zmx session name for a Pane. zmx names its control socket
  /// `<ZMX_DIR>/<ZMX_SESSION_PREFIX><session>`; codans sets no prefix
  /// and uses the PaneID's UUID string, so the name is stable across
  /// launches (the property that makes re-attach work).
  static func session(for paneID: PaneID) -> String {
    paneID.raw.uuidString
  }

  /// `[<zmx>, attach, <session>, (--restore-from <path>)]`, prepended by
  /// libghostty to the resolved shell command. Already-split arguments, so
  /// no quoting. `restoreFrom`, when a non-empty path, makes zmx seed a
  /// freshly created session from that snapshot; zmx consumes the flag
  /// wherever it appears, so it never reaches the shell command after it.
  static func wrapperArgv(zmxPath: String, session: String, restoreFrom: String? = nil) -> [String] {
    var argv = [zmxPath, "attach", session]
    if let snapshot = restoreFrom?.trimmingCharacters(in: .whitespacesAndNewlines), !snapshot.isEmpty {
      argv += ["--restore-from", snapshot]
    }
    return argv
  }

  /// Compose `<zmx> attach <session> [/bin/sh -c <userCommand>]`. When
  /// `userCommand` is nil/empty the attached session runs zmx's own login
  /// shell.
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
