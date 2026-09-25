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

/// Answers a `ManifestRequest` for one directory. The only place that touches
/// a filesystem — parsers stay pure and never know which reader fed them.
nonisolated protocol ManifestReader: Sendable {
  func read(_ request: ManifestRequest, in directory: String) async -> ManifestSnapshot
}

/// Manifests are small text files; anything bigger is generated or vendored
/// and not worth parsing (or shipping over SSH).
nonisolated enum ManifestReadLimits {
  static let maxFileBytes = 1_048_576
}

// MARK: - Local

nonisolated struct LocalManifestReader: ManifestReader {
  func read(_ request: ManifestRequest, in directory: String) async -> ManifestSnapshot {
    let base = URL(fileURLWithPath: directory, isDirectory: true)
    let fileManager = FileManager.default
    var contents: [String: String] = [:]
    var present = Set<String>()

    for path in request.contentPaths {
      let url = base.appendingPathComponent(path)
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeRegular
      else { continue }
      present.insert(path)
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      if size <= ManifestReadLimits.maxFileBytes, let text = try? String(contentsOf: url, encoding: .utf8) {
        contents[path] = text
      }
    }
    for path in request.presencePaths where fileManager.fileExists(atPath: base.appendingPathComponent(path).path) {
      present.insert(path)
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
  /// Separates content paths from presence paths in the positional list.
  static let presenceSeparator = "--presence--"

  /// `$1` is the directory; then content paths, the separator, presence
  /// paths. Paths travel as positionals so they never touch script parsing.
  static let script = """
    cd -- "$1" 2>/dev/null || exit 0
    shift
    mode=content
    for f in "$@"; do
      if [ "$f" = "\(presenceSeparator)" ]; then mode=presence; continue; fi
      if [ "$mode" = content ]; then
        # BSD `wc` pads its count with spaces; arithmetic expansion strips them.
        if [ -f "$f" ] && [ "$(( $(wc -c < "$f") ))" -le \(ManifestReadLimits.maxFileBytes) ]; then
          printf '\(fileMarker)%s\(markerSuffix)\\n' "$f"
          cat -- "$f"
          printf '\\n'
        fi
      elif [ -e "$f" ]; then
        printf '\(presentMarker)%s\(markerSuffix)\\n' "$f"
      fi
    done
    """

  func read(_ request: ManifestRequest, in directory: String) async -> ManifestSnapshot {
    let positionals = [directory] + request.contentPaths + [Self.presenceSeparator] + request.presencePaths
    let (executable, sshArguments) = SSHCommand.invocation(
      host: host,
      executable: "/bin/sh",
      arguments: ["-c", Self.script, "sh"] + positionals,
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    let outcome = await runner.run(
      executable: executable,
      arguments: sshArguments,
      env: ProcessInfo.processInfo.environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: Self.timeout,
      maxOutputBytes: ManifestReadLimits.maxFileBytes * 4
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
