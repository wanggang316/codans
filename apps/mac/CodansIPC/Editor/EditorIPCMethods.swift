import Foundation

/// Namespaced method constants for the `editor.*` IPC surface. Kept as string constants (not an
/// enum) so the `codans` CLI and the app can compare wire methods without coupling to a Swift enum's
/// rawValue indirection.
///
/// Global and per-Project editor defaults are distinct verbs (`setGlobalDefault` vs
/// `setProjectDefault`) for clarity.
public nonisolated enum EditorIPCMethod {
  public static let describe = "editor.describe"
  public static let open = "editor.open"
  public static let setGlobalDefault = "editor.setGlobalDefault"
  public static let setProjectDefault = "editor.setProjectDefault"
}
