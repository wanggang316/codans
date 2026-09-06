import Darwin
import Foundation

/// Which of the two codans builds this process is. Everything that must keep
/// a locally-built Debug app apart from the installed Release app — config
/// root, zmx socket directory, IPC socket, CLI command name — derives its
/// spelling from here, so the decision is made exactly once.
///
/// Build type, not bundle identity, is the discriminator on purpose. The
/// `codans` CLI links this module too, and a Debug-built CLI must resolve the
/// same paths as its Debug-built app; `#if DEBUG` gives both the same answer
/// at compile time, whereas reading `Bundle.main` would diverge (the CLI's
/// bundle is the CLI). This is the only `#if DEBUG` in the codebase that
/// changes a runtime value; anything new that depends on the channel should
/// switch on `current` rather than add another.
public nonisolated enum BuildChannel: String, Sendable, CaseIterable {
  case development
  case release

  public static let current: BuildChannel = {
    #if DEBUG
      return .development
    #else
      return .release
    #endif
  }()

  /// The channel a process of the *other* build would be. Used to recognise
  /// values inherited from a host app of the other channel.
  public var other: BuildChannel {
    switch self {
    case .development: return .release
    case .release: return .development
    }
  }

  /// Product slug every channel-scoped resource is named after:
  /// `~/.config/<slug>`, `~/Library/Caches/<slug>`, `/tmp/<slug>-<uid>.sock`,
  /// `/usr/local/bin/<slug>`.
  public var slug: String {
    switch self {
    case .development: return "codans-dev"
    case .release: return "codans"
    }
  }

  /// IPC socket for this channel and user.
  public func socketPath(uid: uid_t = getuid()) -> String {
    "/tmp/\(slug)-\(uid).sock"
  }

  /// The socket path with the uid left symbolic, for help text and docs.
  public var socketPathTemplate: String {
    "/tmp/\(slug)-<uid>.sock"
  }
}
