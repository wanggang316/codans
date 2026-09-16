import CodansCore
import Foundation

/// File targets stay separate from directory opening: line suffixes and CLI flags
/// must never change the meaning of an arbitrary repository path.
nonisolated enum EditorFileOpen {
  static func target(worktree: URL, relativePath: String, local: Bool) throws -> URL {
    let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard worktree.isFileURL, !relativePath.isEmpty, !relativePath.hasPrefix("/"),
      !relativePath.contains("\0"), !parts.contains(".."), !parts.contains("."),
      !parts.contains("")
    else {
      throw EditorError.launchFailed(reason: "The diff file path is not a valid worktree-relative path.")
    }
    let root = worktree.standardizedFileURL
    let file = root.appendingPathComponent(relativePath).standardizedFileURL
    if local {
      let resolvedRoot = root.resolvingSymlinksInPath().path
      let resolvedFile = file.resolvingSymlinksInPath().path
      guard resolvedFile.hasPrefix(resolvedRoot == "/" ? "/" : resolvedRoot + "/") else {
        throw EditorError.launchFailed(reason: "The diff file resolves outside its worktree.")
      }
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory),
        !directory.boolValue
      else {
        throw EditorError.launchFailed(reason: "The current file no longer exists in this worktree.")
      }
    }
    return file
  }

  static func invocation(
    editorID: EditorID, filePath: String, line: Int?, host: RemoteHost? = nil
  ) -> RemoteEditorOpen.Invocation? {
    // Colon-bearing filenames cannot safely use the editors' path:line syntax.
    let line = line.flatMap { $0 > 0 && !filePath.contains(":") ? $0 : nil }
    if let host {
      guard
        var invocation = RemoteEditorOpen.invocation(
          editorID: editorID, host: host, remotePath: filePath
        )
      else { return nil }
      if let line {
        if editorID == "zed" {
          invocation.arguments[0] += ":\(line)"
        } else {
          invocation.arguments = ["--remote", "ssh-remote+\(host.sshDestination)", "--goto", "\(filePath):\(line)"]
        }
      }
      return invocation
    }
    if let cliName = RemoteEditorOpen.vscodeFamilyCLIName[editorID] {
      return .init(
        executableRelativePath: "Contents/Resources/app/bin/\(cliName)",
        arguments: line.map { ["--goto", "\(filePath):\($0)"] } ?? ["--", filePath]
      )
    }
    let cli: String
    switch editorID {
    case "zed": cli = "Contents/MacOS/cli"
    case "sublimeText": cli = "Contents/SharedSupport/bin/subl"
    default: return nil
    }
    return .init(
      executableRelativePath: cli,
      arguments: ["--", line.map { "\(filePath):\($0)" } ?? filePath]
    )
  }
}
