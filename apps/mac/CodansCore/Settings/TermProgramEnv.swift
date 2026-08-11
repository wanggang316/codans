import Foundation

/// The `TERM_PROGRAM` / `TERM_PROGRAM_VERSION` product marker codans
/// stamps into every spawned pane's environment so scripts and coding
/// agents can cheaply detect "am I running inside codans" (the same
/// convention Terminal.app, iTerm2, and ghostty follow).
///
/// Unlike `BuiltinEnvVar` these are not per-worktree values and are not
/// surfaced as read-only rows in the Environment editor — they are
/// app-constant and written last by `HierarchyManager.resolvedEnv`, so
/// neither an inherited parent value (codans launched from another
/// terminal) nor a project-defined `envVars` entry can misreport the
/// hosting product.
public enum TermProgramEnv {
  /// Environment key identifying the hosting terminal product.
  public static let programKey = "TERM_PROGRAM"
  /// The value written for `TERM_PROGRAM`.
  public static let program = "codans"
  /// Environment key carrying the hosting product's marketing version.
  public static let versionKey = "TERM_PROGRAM_VERSION"
}
