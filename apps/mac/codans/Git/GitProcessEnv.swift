import Foundation

/// Environment construction for every `git` subprocess. The child receives only `PATH` and
/// `HOME` from the parent, plus a forced `LC_ALL=C.UTF-8`. Every `GIT_*` variable that could
/// redirect the invocation (to a different config file, a different working tree, an external
/// diff tool, an interactive prompter) is explicitly stripped even if present in the parent.
///
/// Historically aligned with an editor-subprocess environment (`EditorEnv`) — that module
/// retired in C8a when `EditorService` moved to NSWorkspace; Git is now the only subprocess
/// boundary applying the allowlist-plus-strip discipline.
///
/// Declared `nonisolated` because the app target defaults to `@MainActor` — these members are
/// pure and safe to call from any context.
nonisolated enum GitProcessEnv {
  /// Parent-environment keys that propagate to the child.
  static let allowlist: [String] = ["PATH", "HOME"]
  /// Values always set on the child, regardless of parent environment.
  static let forced: [String: String] = ["LC_ALL": "C.UTF-8"]
  /// Keys explicitly stripped from the child even if the parent had them set.
  static let forbidden: Set<String> = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_EDITOR",
    "GIT_PAGER",
    "GIT_EXTERNAL_DIFF",
    "GIT_EXEC_PATH",
    "GIT_CONFIG",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_GLOBAL",
    "GIT_SSH",
    "GIT_ASKPASS",
  ]

  /// Builds the child env. The result contains the allowlisted keys (when present in parent)
  /// and the forced overlay, and no forbidden key. In debug builds a precondition catches any
  /// forbidden key that slipped through the filter.
  static func build(from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env: [String: String] = [:]
    for key in allowlist {
      if let value = parent[key] { env[key] = value }
    }
    for (key, value) in forced { env[key] = value }
    #if DEBUG
      for key in forbidden {
        precondition(env[key] == nil, "GitProcessEnv: forbidden key '\(key)' leaked into child env")
      }
    #endif
    return env
  }
}
