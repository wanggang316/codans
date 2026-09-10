import Foundation

/// The on-disk shape of a workspace, spelled once.
///
/// A workspace is a plain folder that holds several git checkouts and a
/// manifest describing them. The manifest lives in the same per-root state
/// directory handoff uses (`.codans/`), so a workspace root carries exactly
/// one codans-owned directory. Every consumer — the manifest store, the
/// reconcile path that detects a workspace at add-time, and the agent-facing
/// docs — spells the path through this type.
public nonisolated enum WorkspaceLayout {
  /// Per-root state directory codans owns. Shared with `HandoffLayout` so a
  /// workspace root and a worktree root look alike on disk.
  public static let stateDirectoryName = HandoffLayout.stateDirectoryName
  /// Manifest file inside the state directory.
  public static let manifestFileName = "workspace.json"

  /// `.codans/workspace.json` — the manifest as an agent sees it from the
  /// workspace root.
  public static var rootRelativeManifestPath: String {
    "\(stateDirectoryName)/\(manifestFileName)"
  }

  public static func stateDirectoryURL(rootURL: URL) -> URL {
    rootURL.appending(path: stateDirectoryName, directoryHint: .isDirectory)
  }

  public static func manifestURL(rootURL: URL) -> URL {
    stateDirectoryURL(rootURL: rootURL)
      .appending(path: manifestFileName, directoryHint: .notDirectory)
  }

  public static func manifestURL(rootPath: String) -> URL {
    manifestURL(rootURL: URL(fileURLWithPath: rootPath, isDirectory: true))
  }

  /// Where new workspaces are created when the caller names no folder:
  /// `~/.codans/workspaces/<folder>`. Mirrors the worktree base directory
  /// (`~/.codans/repos/<project>`), so both codans-managed checkouts live
  /// under one parent the user already knows.
  public static func defaultWorkspacesDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home.appending(path: ".codans/workspaces", directoryHint: .isDirectory)
  }

  /// Folder name derived from a workspace title: lowercased, non-alphanumerics
  /// collapsed to single dashes, trimmed. Falls back to `workspace` when
  /// nothing survives, so a title of punctuation still yields a usable path.
  public static func folderName(forTitle title: String) -> String {
    var result = ""
    var pendingDash = false
    for scalar in title.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        if pendingDash, !result.isEmpty {
          result.append("-")
        }
        pendingDash = false
        result.unicodeScalars.append(scalar)
      } else {
        pendingDash = true
      }
    }
    return result.isEmpty ? "workspace" : result
  }
}
