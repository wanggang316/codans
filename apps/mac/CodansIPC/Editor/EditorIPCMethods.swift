import Foundation

/// Namespaced method constants for the `editor.*` IPC surface. Kept as string constants (not an
/// enum) so the `codans` CLI and the app can compare wire methods without coupling to a Swift enum's
/// rawValue indirection.
///
/// C8a Phase 4c renamed `editor.setDefault` → `editor.setGlobalDefault` (per-project override
/// moves to a separate verb for clarity). `editor.setProjectDefault` is new in C8a.
public nonisolated enum EditorIPCMethod {
  public static let describe = "editor.describe"
  public static let open = "editor.open"
  public static let setGlobalDefault = "editor.setGlobalDefault"
  public static let setProjectDefault = "editor.setProjectDefault"
}
