import Foundation

/// Title of one pane (ADR 0009). A pane card header shows it, and a tab chip
/// shows the title of its tab's selected pane, so the two never disagree.
/// It comes from the terminal (OSC 0/2 and the working directory), never
/// from OSC 7501.
public nonisolated enum PaneTitle {
  /// Title of a pane with no title and no working directory.
  public static let placeholder = "Terminal"

  /// Picks the pane title, in this order:
  /// 1. the shell is at its prompt → the working directory, whatever title
  ///    the shell sets (shell frameworks set titles in many formats);
  /// 2. the last non-empty OSC 0/2 title, sanitized. A shell that clears the
  ///    title while a command runs does not erase it;
  /// 3. the working directory, when the pane has had no title.
  ///
  /// `workingDirectories` are tried in order (the live one, then the
  /// persisted one); the home directory shows as `~`. Nil when nothing is
  /// known.
  public static func resolve(
    isAtShellPrompt: Bool,
    lastTitle: String?,
    workingDirectories: [String?],
    homeDirectory: String = NSHomeDirectory()
  ) -> String? {
    let directory =
      workingDirectories
      .lazy
      .compactMap { $0 }
      .first { !$0.isEmpty }
      .map { abbreviatingHome($0, homeDirectory: homeDirectory) }
    if isAtShellPrompt, let directory { return directory }
    return UntrustedDisplayText.sanitized(lastTitle) ?? directory
  }

  /// `path` with a leading home directory shown as `~`.
  public static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
    let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
    guard !home.isEmpty else { return path }
    if path == home || path == home + "/" { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }
}
