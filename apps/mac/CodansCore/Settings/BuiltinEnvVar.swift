import Foundation

/// Environment variables codans provides for every spawned pane,
/// resolved per-worktree at spawn time. These are *reserved*: the
/// Settings → Environment editor pins read-only rows for them and refuses
/// a user key of the same name, and `HierarchyManager` writes them last
/// when building a pane's environment so a user-defined `envVars` entry
/// can never shadow the real path.
///
/// These share the `CODANS_` prefix with the internal IPC/runtime
/// variables (e.g. `CODANS_WORKTREE_ID`, `CODANS_SOCKET_PATH`) but are
/// part of the user-facing scripting contract documented in the
/// Environment pane.
public enum BuiltinEnvVar: String, Sendable, CaseIterable {
  /// Absolute path of the worktree the pane belongs to.
  case worktreePath = "CODANS_WORKTREE_PATH"
  /// Absolute path of the Project root the worktree was created from.
  case rootPath = "CODANS_ROOT_PATH"

  /// The literal name written into the child process environment.
  public var key: String { rawValue }

  /// One-line description of what the variable resolves to, shown as the
  /// value of the read-only row in the Environment editor (the concrete
  /// value varies per pane, so the editor documents the meaning instead).
  public var summary: String {
    switch self {
    case .worktreePath: return "Absolute path of the current worktree"
    case .rootPath: return "Absolute path of the project root"
    }
  }

  /// Names a user cannot define by hand in the Environment editor.
  public static let reservedKeys: Set<String> = Set(allCases.map(\.rawValue))
}
