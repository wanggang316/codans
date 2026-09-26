import CodansCore
import Foundation

/// Directory a manifest scan reads from: a local path, or a path on an SSH
/// host for Server projects.
nonisolated struct ManifestLocation: Equatable, Sendable {
  var directory: String
  var host: RemoteHost?

  /// The checkout to scan for a Project: `worktreeID` when it belongs to the
  /// Project, else the Project's selected worktree — branches can carry
  /// different manifests — else the Project root. Server projects read on
  /// their host. nil when the Project is gone.
  static func resolve(projectID: ProjectID, worktreeID: WorktreeID?, in catalog: Catalog) -> ManifestLocation? {
    guard let project = catalog.projects.first(where: { $0.id == projectID }) else { return nil }
    let directory =
      [worktreeID, project.selectedWorktreeID]
      .lazy
      .compactMap { id in project.worktrees.first(where: { $0.id == id })?.path }
      .first ?? project.rootPath
    return ManifestLocation(directory: directory, host: project.remoteHost)
  }
}

/// Answers a `ManifestRequest` for a directory tree: every requested file name
/// found at the root or in a subdirectory `scope` allows, keyed by its path
/// relative to `directory`. The only place that touches a filesystem — parsers
/// stay pure and never know which reader fed them.
nonisolated protocol ManifestReader: Sendable {
  func read(_ request: ManifestRequest, in directory: String, scope: ManifestScope) async -> ManifestSnapshot
}

/// Manifests are small text files; anything bigger is generated or vendored
/// and not worth parsing (or shipping over SSH).
nonisolated enum ManifestReadLimits {
  static let maxFileBytes = 1_048_576
}

// MARK: - Local

nonisolated struct LocalManifestReader: ManifestReader {
  func read(_ request: ManifestRequest, in directory: String, scope: ManifestScope) async -> ManifestSnapshot {
    let fileManager = FileManager.default
    let contentNames = Set(request.contentPaths)
    let presenceNames = Set(request.presencePaths)
    var contents: [String: String] = [:]
    var present = Set<String>()

    // Breadth-first to `scope.maxDepth`, listing each directory once rather
    // than probing every requested name in every directory.
    var queue: [(relative: String, depth: Int)] = [("", 0)]
    while !queue.isEmpty {
      let (relative, depth) = queue.removeFirst()
      let url = relative.isEmpty
        ? URL(fileURLWithPath: directory, isDirectory: true)
        : URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(relative, isDirectory: true)
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
      else { continue }
      for entry in entries {
        let name = entry.lastPathComponent
        let path = relative.isEmpty ? name : relative + "/" + name
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values?.isDirectory == true {
          // Symlinked directories are skipped: they can loop, and they point
          // outside the checkout often enough to be noise.
          if depth < scope.maxDepth, values?.isSymbolicLink != true, scope.shouldDescend(into: name) {
            queue.append((path, depth + 1))
          }
        } else if contentNames.contains(name) {
          present.insert(path)
          if (values?.fileSize ?? 0) <= ManifestReadLimits.maxFileBytes,
            let text = try? String(contentsOf: entry, encoding: .utf8)
          {
            contents[path] = text
          }
        } else if presenceNames.contains(name) {
          present.insert(path)
        }
      }
    }
    return ManifestSnapshot(contents: contents, presentPaths: present)
  }
}

// MARK: - Remote

/// Reads every requested manifest in one SSH round trip riding the shared
/// ControlMaster. The host streams marker-delimited sections; bytes before
/// the first marker (login-shell banners) are ignored. Best effort: an
/// unreachable host or a failed `cd` yields an empty snapshot, which reads as
/// "no suggestions", never an error.
nonisolated struct RemoteManifestReader: ManifestReader {
  let host: RemoteHost
  var runner: any CommandRunner = FoundationCommandRunner()

  static let timeout: Duration = .seconds(15)
  static let fileMarker = "===CODANS-MANIFEST "
  static let presentMarker = "===CODANS-PRESENT "
  static let markerSuffix = "==="

  /// Host-side script: `find` walks the tree with the same pruning as the
  /// local reader, then each hit is streamed as file contents or a presence
  /// marker. Names come from our own request (fixed manifest file names), and
  /// are single-quoted anyway; the directory travels as `$1`.
  static func script(for request: ManifestRequest, scope: ManifestScope) -> String {
    let quote = SSHCommand.shellQuote
    let pruned = (["'.*'"] + scope.ignoredDirectoryNames.sorted().map(quote))
      .map { "-name \($0)" }.joined(separator: " -o ")
    let wanted = (request.contentPaths + request.presencePaths).map { "-name \(quote($0))" }
      .joined(separator: " -o ")
    let contentCase = request.contentPaths.map(quote).joined(separator: "|")
    return """
      cd -- "$1" 2>/dev/null || exit 0
      find . -mindepth 1 -maxdepth \(scope.maxDepth + 1) \\( -type d \\( \(pruned) \\) -prune \\) \\
        -o -type f \\( \(wanted) \\) -print 2>/dev/null |
      while IFS= read -r f; do
        f=${f#./}
        case "${f##*/}" in
          \(contentCase.isEmpty ? "''" : contentCase))
            # BSD `wc` pads its count with spaces; arithmetic expansion strips them.
            if [ "$(( $(wc -c < "$f") ))" -le \(ManifestReadLimits.maxFileBytes) ]; then
              printf '\(fileMarker)%s\(markerSuffix)\\n' "$f"
              cat -- "$f"
              printf '\\n'
            else
              printf '\(presentMarker)%s\(markerSuffix)\\n' "$f"
            fi
            ;;
          *) printf '\(presentMarker)%s\(markerSuffix)\\n' "$f" ;;
        esac
      done
      """
  }

  func read(_ request: ManifestRequest, in directory: String, scope: ManifestScope) async -> ManifestSnapshot {
    let (executable, sshArguments) = SSHCommand.invocation(
      host: host,
      executable: "/bin/sh",
      arguments: ["-c", Self.script(for: request, scope: scope), "sh", directory],
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    let outcome = await runner.run(
      executable: executable,
      arguments: sshArguments,
      env: ProcessInfo.processInfo.environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: Self.timeout,
      maxOutputBytes: ManifestReadLimits.maxFileBytes * 8
    )
    guard case .exited(let code, let stdout, _, let overflow) = outcome, code == 0, !overflow else {
      return ManifestSnapshot()
    }
    return Self.parse(String(decoding: stdout, as: UTF8.self))
  }

  /// Splits the marker stream into a snapshot. Each file section runs to the
  /// next marker. The newline the script appends after `cat` is exactly the
  /// line break that ends the section, so joining a section's lines restores
  /// the file byte for byte.
  static func parse(_ output: String) -> ManifestSnapshot {
    var contents: [String: String] = [:]
    var present = Set<String>()
    var currentPath: String?
    var lines: [Substring] = []

    func flush() {
      if let path = currentPath {
        contents[path] = lines.joined(separator: "\n")
      }
      currentPath = nil
      lines = []
    }

    // The stream's own final newline terminates the last line; it is not an
    // extra empty line of the last file.
    let body = output.hasSuffix("\n") ? output.dropLast() : Substring(output)
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
      if let path = markerPath(line, prefix: fileMarker) {
        flush()
        currentPath = path
      } else if let path = markerPath(line, prefix: presentMarker) {
        flush()
        present.insert(path)
      } else if currentPath != nil {
        lines.append(line)
      }
    }
    flush()
    return ManifestSnapshot(contents: contents, presentPaths: present)
  }

  private static func markerPath(_ line: Substring, prefix: String) -> String? {
    guard line.hasPrefix(prefix), line.hasSuffix(markerSuffix), line.count > prefix.count + markerSuffix.count
    else { return nil }
    return String(line.dropFirst(prefix.count).dropLast(markerSuffix.count))
  }
}
