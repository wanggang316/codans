import Foundation
import CodansCore

/// Pure unified-diff parser. Consumes the bytes produced by `git diff` / `git show` and emits
/// a typed `UnifiedDiff`. Does no I/O, holds no state beyond the current file block.
///
/// Enforces the design's 50 000-line cutoff: on the 50 001st body line (context/added/removed)
/// the parser throws `GitError.diffTooLarge`. Callers render a "Copy command" placeholder
/// instead of a rendered diff past this point.
///
/// **Scope.** Handles the two-parent unified-diff form (`diff --git ...`, `@@ -a,b +c,d @@`).
/// The **combined-diff** form that `git show` emits for merge commits (`diff --cc` with `@@@`
/// triple-separators) is out of scope for this parser. A merge commit will arrive from the
/// service layer as a unified diff vs. a chosen parent; merge traversal is not a v1 feature.
///
/// Declared `nonisolated` — the parser is pure over its bytes; the app target's
/// `@MainActor` default does not apply to value computations.
nonisolated enum DiffParser {
  static let maxDiffLines = 50_000

  static func parse(_ bytes: Data, scope: DiffScope) throws -> UnifiedDiff {
    guard let text = String(data: bytes, encoding: .utf8) else {
      throw GitError.unparsable(context: "output was not UTF-8")
    }
    if text.isEmpty {
      return UnifiedDiff(scope: scope, files: [])
    }

    var files: [FileChange] = []
    var builder: FileBuilder?
    var lineCount = 0

    // Lines retain their newlines when produced by git; split drops the trailing empty.
    let lines = text.components(separatedBy: "\n")

    for line in lines {
      // New file block. Flush the prior, then start fresh.
      if line.hasPrefix("diff --git ") {
        if let prev = builder { files.append(try prev.build()) }
        builder = try FileBuilder(diffGitLine: line)
        continue
      }
      guard var current = builder else {
        // Leading content before the first `diff --git`. git never emits this; treat as a
        // parse error only if non-empty (trailing newline produces "" at end of split).
        if line.isEmpty { continue }
        throw GitError.unparsable(context: "content before first 'diff --git': \(line.prefix(80))")
      }

      if current.stage == .header {
        if try current.consumeHeaderLine(line) {
          builder = current
          continue
        }
      }
      // stage == .hunks
      if line.hasPrefix("@@") {
        try current.startHunk(headerLine: line)
        builder = current
        continue
      }
      if line.isEmpty, current.activeHunk == nil {
        builder = current
        continue
      }
      if current.activeHunk != nil {
        try current.appendBodyLine(line)
        if line.first == " " || line.first == "+" || line.first == "-" {
          lineCount += 1
          if lineCount > maxDiffLines { throw GitError.diffTooLarge }
        }
      }
      builder = current
    }

    if let prev = builder { files.append(try prev.build()) }
    return UnifiedDiff(scope: scope, files: files)
  }
}

// MARK: - FileBuilder

extension DiffParser {
  /// Internal accumulator for one `diff --git ...` block. Order-sensitive: header lines arrive
  /// before any `@@`, then only body lines until the next `diff --git` or EOF.
  nonisolated fileprivate struct FileBuilder {
    nonisolated enum Stage: Equatable { case header, hunks }

    let oldPath: String
    let newPath: String
    var stage: Stage = .header
    var kind: FileChange.Kind = .modified
    var isBinary = false
    var linesAdded = 0
    var linesRemoved = 0
    var hunks: [DiffHunk] = []
    var activeHunk: HunkBuilder?
    var sawNewFileMode = false
    var sawDeletedFileMode = false
    var sawOldMode: String?
    var sawNewMode: String?
    var renameFrom: String?
    var copyFrom: String?
    var sawIndexOrModeChange = false

    /// Parses the `diff --git a/<path> b/<path>` header line. git quotes paths containing
    /// unusual bytes per C rules (`"..."` with `\t`/`\\`/octal), but for in-repo paths we only
    /// need the simple case. Quoted paths are preserved verbatim.
    init(diffGitLine: String) throws {
      guard diffGitLine.hasPrefix("diff --git ") else {
        throw GitError.unparsable(context: "expected 'diff --git' prefix: \(diffGitLine)")
      }
      let rest = diffGitLine.dropFirst("diff --git ".count)
      // Split the two `a/.../ b/...` paths. For unquoted paths, split on " b/".
      if let range = rest.range(of: " b/") {
        let aPart = rest[..<range.lowerBound]  // e.g. "a/foo/bar.swift"
        let bPart = rest[range.upperBound...]  // e.g. "foo/bar.swift"
        let aPath = aPart.hasPrefix("a/") ? String(aPart.dropFirst(2)) : String(aPart)
        self.oldPath = aPath
        self.newPath = String(bPart)
      } else {
        // Fallback: keep whole line as both paths; parser proceeds.
        self.oldPath = String(rest)
        self.newPath = String(rest)
      }
    }

    /// Consumes one potential header line. Returns `true` if consumed (caller moves to the
    /// next line); `false` means the caller should reinterpret the line (usually as body).
    mutating func consumeHeaderLine(_ line: String) throws -> Bool {
      if consumeModeLine(line) { return true }
      if consumeRenameOrCopyLine(line) { return true }
      if consumeBinaryOrDiffHeaderLine(line) { return true }
      if line.hasPrefix("similarity index ") { return true }
      if line.hasPrefix("dissimilarity index ") { return true }
      if line.hasPrefix("index ") {
        sawIndexOrModeChange = true
        return true
      }
      if line.isEmpty { return true }
      // Unknown header line — fall through to .hunks handling. If the next line is `@@`,
      // fine. If not, the body handler classifies it.
      stage = .hunks
      return false
    }

    /// `old mode` / `new mode` / `new file mode` / `deleted file mode`.
    private mutating func consumeModeLine(_ line: String) -> Bool {
      if line.hasPrefix("old mode ") {
        sawOldMode = String(line.dropFirst("old mode ".count))
        sawIndexOrModeChange = true
        return true
      }
      if line.hasPrefix("new mode ") {
        sawNewMode = String(line.dropFirst("new mode ".count))
        sawIndexOrModeChange = true
        return true
      }
      if line.hasPrefix("new file mode ") {
        sawNewFileMode = true
        kind = .added
        sawIndexOrModeChange = true
        return true
      }
      if line.hasPrefix("deleted file mode ") {
        sawDeletedFileMode = true
        kind = .deleted
        sawIndexOrModeChange = true
        return true
      }
      return false
    }

    /// `rename from/to` + `copy from/to`. Each pair encodes either a rename or a copy.
    private mutating func consumeRenameOrCopyLine(_ line: String) -> Bool {
      if line.hasPrefix("rename from ") {
        renameFrom = String(line.dropFirst("rename from ".count))
        return true
      }
      if line.hasPrefix("rename to ") {
        if let from = renameFrom { kind = .renamed(from: from) }
        return true
      }
      if line.hasPrefix("copy from ") {
        copyFrom = String(line.dropFirst("copy from ".count))
        return true
      }
      if line.hasPrefix("copy to ") {
        if let from = copyFrom { kind = .copied(from: from) }
        return true
      }
      return false
    }

    /// `Binary files X and Y differ` + `--- <path>` / `+++ <path>`.
    private mutating func consumeBinaryOrDiffHeaderLine(_ line: String) -> Bool {
      if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
        isBinary = true
        stage = .hunks  // no hunks will follow; stage transition prevents re-entry
        return true
      }
      if line.hasPrefix("--- ") { return true }
      if line.hasPrefix("+++ ") {
        stage = .hunks
        return true
      }
      return false
    }

    mutating func startHunk(headerLine: String) throws {
      // Flush any prior hunk.
      if let prev = activeHunk { hunks.append(prev.finalize()) }

      let parsed = try DiffParser.parseHunkHeader(headerLine)
      activeHunk = HunkBuilder(
        header: headerLine,
        oldStart: parsed.oldStart,
        oldCount: parsed.oldCount,
        newStart: parsed.newStart,
        newCount: parsed.newCount
      )
    }

    mutating func appendBodyLine(_ line: String) throws {
      guard var hunk = activeHunk else { return }
      if line.isEmpty {
        // Empty line inside a hunk is a context line with no text content.
        hunk.lines.append(DiffLine(kind: .context, text: ""))
        activeHunk = hunk
        return
      }
      let marker = line.first
      let rest = String(line.dropFirst())
      let kindForLine: DiffLine.Kind
      switch marker {
      case " ":
        kindForLine = .context
      case "+":
        kindForLine = .added
        linesAdded += 1
      case "-":
        kindForLine = .removed
        linesRemoved += 1
      case "\\":
        kindForLine = .noNewlineMarker
      default:
        // Unknown marker — treat as context to avoid losing content; log path handles the rest.
        kindForLine = .context
      }
      hunk.lines.append(DiffLine(kind: kindForLine, text: rest))
      activeHunk = hunk
    }

    func build() throws -> FileChange {
      var finalKind = kind
      if case .modified = finalKind, isBinary, !sawIndexOrModeChange {
        // Purely binary mention is fine; no-op.
      }
      // Mode-only change (old mode / new mode with no hunks and no rename/copy/add/delete).
      if case .modified = finalKind,
        sawOldMode != nil, sawNewMode != nil,
        hunks.isEmpty, activeHunk == nil, !isBinary
      {
        finalKind = .typeChanged
      }

      var finalHunks = hunks
      if let last = activeHunk { finalHunks.append(last.finalize()) }

      let id: String
      switch finalKind {
      case .deleted: id = oldPath
      default: id = newPath
      }

      return FileChange(
        id: id,
        kind: finalKind,
        isBinary: isBinary,
        linesAdded: linesAdded,
        linesRemoved: linesRemoved,
        hunks: finalHunks
      )
    }
  }

  nonisolated fileprivate struct HunkBuilder {
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    var lines: [DiffLine] = []

    func finalize() -> DiffHunk {
      DiffHunk(
        header: header,
        oldStart: oldStart, oldCount: oldCount,
        newStart: newStart, newCount: newCount,
        lines: lines
      )
    }
  }

  /// Parses a hunk header of the form `@@ -a[,b] +c[,d] @@ [section hint]`. Throws
  /// `.unparsable` when the shape does not match.
  nonisolated fileprivate struct HunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
  }

  nonisolated fileprivate static func parseHunkHeader(_ line: String) throws -> HunkHeader {
    // We need the first "@@ ... @@" block. After it, optional section hint.
    guard line.hasPrefix("@@ ") else {
      throw GitError.unparsable(context: "hunk header missing '@@ ' prefix: \(line)")
    }
    let rest = line.dropFirst("@@ ".count)
    guard let closingRange = rest.range(of: " @@") else {
      throw GitError.unparsable(context: "hunk header missing ' @@' terminator: \(line)")
    }
    let spec = rest[..<closingRange.lowerBound]  // e.g. "-1,3 +1,4" or "-0,0 +1"
    let parts = spec.split(separator: " ")
    guard parts.count == 2,
      parts[0].hasPrefix("-"),
      parts[1].hasPrefix("+")
    else {
      throw GitError.unparsable(context: "hunk header malformed spec: \(line)")
    }
    let (oldStart, oldCount) = try parsePair(parts[0].dropFirst(), line: line)
    let (newStart, newCount) = try parsePair(parts[1].dropFirst(), line: line)
    return HunkHeader(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
  }

  nonisolated fileprivate static func parsePair(_ s: Substring, line: String) throws -> (Int, Int) {
    if let comma = s.firstIndex(of: ",") {
      guard
        let start = Int(s[..<comma]),
        let count = Int(s[s.index(after: comma)...])
      else {
        throw GitError.unparsable(context: "hunk header integer parse failed: \(line)")
      }
      return (start, count)
    } else {
      guard let start = Int(s) else {
        throw GitError.unparsable(context: "hunk header integer parse failed: \(line)")
      }
      return (start, 1)
    }
  }
}
