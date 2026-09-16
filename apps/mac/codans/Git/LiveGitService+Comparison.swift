import CodansCore
import CryptoKit
import Foundation

extension LiveGitService {
  static let comparisonContentLimit = 2 * 1024 * 1024

  func comparison(at path: URL, scope: GitComparisonScope, base: String?) async throws -> GitComparisonSnapshot {
    try await ensureIsRepo(at: path)
    var endpoints: [String] = []
    var label = "HEAD"
    switch scope {
    case .outgoing:
      let head = try await comparisonRevision("HEAD", at: path)
      let resolved = try await comparisonBase(base, at: path)
      let ancestor = try await run(arguments: ["merge-base", resolved.sha, head], cwd: path)
      let mergeBase = (String(data: ancestor, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard GitShaValidator.isValid(mergeBase) else {
        throw GitError.invalidInput("No common ancestor with target branch")
      }
      endpoints = [mergeBase, head]
      label = resolved.label
    case .all, .staged:
      let head: String
      do { head = try await comparisonRevision("HEAD", at: path) } catch GitError.exec {
        // hash-object without -w computes the correct empty-tree ID for either hash format.
        let bytes = try await run(arguments: ["hash-object", "-t", "tree", "/dev/null"], cwd: path)
        head = (String(data: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        label = "Empty tree"
      }
      endpoints = scope == .staged ? ["--cached", head] : [head]
    case .unstaged:
      label = "Index"
    }
    let bytes = try await run(
      arguments: [
        "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--raw", "--numstat", "--no-abbrev", "-z", "-M",
      ] + endpoints + ["--"], cwd: path)
    var files = try Self.parseComparison(bytes)
    if scope != .outgoing {
      let unmerged = try await run(arguments: ["ls-files", "--unmerged", "-z"], cwd: path)
      guard let entries = String(data: unmerged, encoding: .utf8) else {
        throw GitError.unparsable(context: "Unsupported filename encoding")
      }
      for entry in entries.split(separator: "\0") {
        guard let separator = entry.firstIndex(of: "\t") else {
          throw GitError.unparsable(context: "Invalid unmerged entry")
        }
        let name = String(entry[entry.index(after: separator)...])
        if let position = files.firstIndex(where: { $0.path == name }) {
          files[position].status = "U"
        } else {
          files.append(.init(path: name, status: "U"))
        }
      }
    }
    if scope != .staged && scope != .outgoing {
      let untracked = try await run(arguments: ["ls-files", "--others", "--exclude-standard", "-z"], cwd: path)
      guard let text = String(data: untracked, encoding: .utf8) else {
        throw GitError.unparsable(context: "Unsupported filename encoding")
      }
      for name in text.split(separator: "\0") where !files.contains(where: { $0.path == name }) {
        files.append(.init(path: String(name), status: "A"))
      }
    }
    let fingerprint = SHA256.hash(
      data: bytes + Data((scope.rawValue + label + files.map(\.path).joined(separator: "\0")).utf8)
    ).map { String(format: "%02x", $0) }.joined()
    return .init(
      id: fingerprint, scope: scope, baseLabel: label, files: files.sorted { $0.path < $1.path },
      repositoryPath: path.path)
  }

  private func comparisonRevision(_ ref: String, at path: URL) async throws -> String {
    let outcome = await invoke(
      arguments: ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"], cwd: path, maxOutputBytes: 1024)
    let bytes = try Self.comparisonOutput(outcome)
    let sha = (String(data: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard GitShaValidator.isValid(sha) else { throw GitError.invalidInput("Invalid comparison revision") }
    return sha
  }

  private func comparisonBase(_ base: String?, at path: URL) async throws -> (label: String, sha: String) {
    if let base, !base.isEmpty { return (base, try await comparisonRevision(base, at: path)) }
    var candidates = ["origin/HEAD", "main", "master"]
    if case .exited(0, let bytes, _, false) = await invoke(
      arguments: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: path, maxOutputBytes: 1024)
    {
      candidates[0] = (String(data: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for candidate in candidates {
      do { return (candidate, try await comparisonRevision(candidate, at: path)) } catch GitError.exec { continue }
    }
    throw GitError.invalidInput("Choose a target branch for Outgoing")
  }

  static func parseComparison(_ bytes: Data) throws -> [GitComparisonFile] {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw GitError.unparsable(context: "Unsupported filename encoding")
    }
    let records = text.components(separatedBy: "\0")
    var index = 0
    var files: [GitComparisonFile] = []
    while index < records.count && records[index].hasPrefix(":") {
      let fields = records[index].dropFirst().split(separator: " ")
      guard fields.count == 5, index + 1 < records.count else {
        throw GitError.unparsable(context: "Invalid raw diff record")
      }
      index += 1
      let firstPath = records[index]
      index += 1
      let status = String(fields[4].prefix(1))
      var newPath = firstPath
      let oldPath: String?
      if status == "R" || status == "C" {
        guard index < records.count else { throw GitError.unparsable(context: "Missing rename destination") }
        newPath = records[index]
        index += 1
        oldPath = firstPath
      } else {
        oldPath = nil
      }
      let file = GitComparisonFile(
        path: newPath, oldPath: oldPath, status: status,
        oldObject: String(fields[2]), newObject: String(fields[3]), oldMode: String(fields[0]),
        newMode: String(fields[1]))
      if let existing = files.firstIndex(where: { $0.path == newPath }) {
        if status == "U" { files[existing] = file }
      } else {
        files.append(file)
      }
    }
    let stats = try GitOutputParser.parseDiffNumstatZ(Data(records[index...].joined(separator: "\0").utf8))
    for position in files.indices {
      if let row = stats.first(where: { $0.newPath == files[position].path }) {
        files[position].additions = row.isBinary ? nil : row.addedLines
        files[position].deletions = row.isBinary ? nil : row.removedLines
        files[position].isBinary = row.isBinary
      }
    }
    return files
  }

  func comparisonContent(at path: URL, snapshot: GitComparisonSnapshot, file: GitComparisonFile) async throws
    -> GitComparisonContent
  {
    guard snapshot.repositoryPath == path.path, snapshot.files.contains(file) else {
      throw GitError.invalidInput("Comparison no longer belongs to this worktree")
    }
    if file.status == "U" { return .init(notice: "Unmerged file. Resolve the conflict in your editor.") }
    if file.isBinary { return .init(notice: "Binary file") }
    if file.oldMode == "160000" || file.newMode == "160000" {
      return .init(notice: "Submodule change: \(file.oldObject) → \(file.newObject)")
    }
    if file.oldMode == "120000" || file.newMode == "120000" { return .init(notice: "Symbolic link change") }
    do {
      let old = try await comparisonBlob(file.oldObject, at: path)
      let new: Data
      if file.status == "D" {
        new = Data()
      } else if snapshot.scope == .all || snapshot.scope == .unstaged {
        new = try await comparisonWorkingFile(file.path, at: path)
      } else {
        new = try await comparisonBlob(file.newObject, at: path)
      }
      guard !old.contains(0), !new.contains(0) else { return .init(notice: "Binary file") }
      guard let oldText = String(data: old, encoding: .utf8), let newText = String(data: new, encoding: .utf8) else {
        return .init(notice: "File encoding is not UTF-8")
      }
      if oldText == newText {
        return .init(notice: "Metadata or path change (\(file.oldMode) → \(file.newMode)); text is unchanged.")
      }
      return .init(oldText: oldText, newText: newText)
    } catch GitError.invalidInput(let reason) {
      return .init(notice: reason)
    } catch GitError.outputTooLarge {
      return .init(notice: "File exceeds the 2 MiB preview limit. Open it in your editor.")
    }
  }

  private func comparisonBlob(_ object: String, at path: URL) async throws -> Data {
    if object.isEmpty || object.allSatisfy({ $0 == "0" }) { return Data() }
    guard GitShaValidator.isValid(object) else { throw GitError.invalidInput("Invalid blob ID") }
    return try Self.comparisonOutput(
      await invoke(arguments: ["cat-file", "blob", object], cwd: path, maxOutputBytes: Self.comparisonContentLimit))
  }

  private func comparisonWorkingFile(_ name: String, at path: URL) async throws -> Data {
    let parts = name.split(separator: "/", omittingEmptySubsequences: false)
    guard !name.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !parts.contains(""), !name.contains("\0")
    else { throw GitError.invalidInput("Invalid relative file path") }
    // Positional arguments preserve spaces, tabs, newlines and shell metacharacters.
    // Reject links at every component instead of following paths outside the worktree.
    let script = """
      name=$1
      current=.
      shift
      for component do
        current="$current/$component"
        if [ -L "$current" ]; then exit 42; fi
      done
      if [ ! -f "./$name" ]; then exit 43; fi
      head -c \(Self.comparisonContentLimit + 1) "./$name"
      """
    var executable = URL(fileURLWithPath: "/bin/sh")
    var arguments = ["-c", script, "diff-view", name] + parts.map(String.init)
    var cwd = path
    var environment = GitProcessEnv.build()
    if let host = await resolveRemoteHost(path) {
      (executable, arguments) = SSHCommand.invocation(
        host: host, executable: "sh", arguments: arguments, workingDirectory: path.path,
        extraOptions: SSHCommand.backgroundProbeOptions)
      cwd = URL(fileURLWithPath: NSHomeDirectory())
      environment = ProcessInfo.processInfo.environment
    }
    let result = await runner.run(
      executable: executable, arguments: arguments, env: environment, cwd: cwd, timeout: Self.sshTimeout,
      maxOutputBytes: Self.comparisonContentLimit)
    if case .exited(let code, _, _, _) = result, code == 42 || code == 43 {
      throw GitError.invalidInput("File is missing, a symlink, or no longer a regular file. Refresh the comparison.")
    }
    return try Self.comparisonOutput(result)
  }

  private static func comparisonOutput(_ outcome: CommandOutcome) throws -> Data {
    switch outcome {
    case .exited(let code, let stdout, let stderr, let overflow):
      if overflow { throw GitError.outputTooLarge }
      if code != 0 { throw GitError.exec(code: code, stderr: (String(data: stderr, encoding: .utf8) ?? "")) }
      return stdout
    case .timedOut: throw GitError.timedOut
    case .spawnFailed(let reason): throw GitError.unparsable(context: reason)
    }
  }
}
