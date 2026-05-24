import Foundation

/// Scope of a diff operation. Used by both `UnifiedDiff` and the service layer in later milestones.
public nonisolated enum DiffScope: Equatable, Hashable, Codable, Sendable {
  case working
  case staged
  case log
  case commit(sha: String)
}

/// Single commit record. `shortID` is always derived from `id` to stay correct under SHA-256.
public nonisolated struct Commit: Equatable, Hashable, Codable, Sendable, Identifiable {
  public let id: String
  public let authorName: String
  public let authorEmail: String
  public let date: Date
  public let subject: String
  public let parents: [String]

  public init(
    id: String,
    authorName: String,
    authorEmail: String,
    date: Date,
    subject: String,
    parents: [String]
  ) {
    self.id = id
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.date = date
    self.subject = subject
    self.parents = parents
  }

  /// Display-only short hash. Always computed from `id`, never parsed from git output,
  /// so SHA-256 repositories and any future hash length work unchanged.
  public var shortID: String { String(id.prefix(7)) }
}

/// A paginated window of commit log results. `hasMore` is derived: the caller gets `limit + 1`
/// and, if the extra row arrives, drops it and sets `hasMore == true`.
public nonisolated struct LogPage: Equatable, Codable, Sendable {
  public struct Cursor: Equatable, Hashable, Codable, Sendable {
    public let offset: Int
    public let limit: Int
    public init(offset: Int, limit: Int) {
      self.offset = offset
      self.limit = limit
    }
  }

  public var cursor: Cursor
  public var commits: [Commit]
  public var hasMore: Bool

  public init(cursor: Cursor, commits: [Commit], hasMore: Bool) {
    self.cursor = cursor
    self.commits = commits
    self.hasMore = hasMore
  }
}

/// Per-file change description. `id` is the post-image path for added/modified/renamed/copied/
/// typeChanged files, and the pre-image path for deletions.
public nonisolated struct FileChange: Equatable, Codable, Sendable, Identifiable {
  public enum Kind: Equatable, Hashable, Codable, Sendable {
    case added
    case deleted
    case modified
    case renamed(from: String)
    case copied(from: String)
    case typeChanged
  }

  public var id: String
  public var kind: Kind
  public var isBinary: Bool
  public var linesAdded: Int
  public var linesRemoved: Int
  public var hunks: [DiffHunk]

  public init(
    id: String,
    kind: Kind,
    isBinary: Bool,
    linesAdded: Int,
    linesRemoved: Int,
    hunks: [DiffHunk]
  ) {
    self.id = id
    self.kind = kind
    self.isBinary = isBinary
    self.linesAdded = linesAdded
    self.linesRemoved = linesRemoved
    self.hunks = hunks
  }
}

/// One `@@ -a,b +c,d @@` hunk. `header` keeps the raw header line (including any trailing
/// section hint git appends) so UI can render it verbatim.
public nonisolated struct DiffHunk: Equatable, Codable, Sendable {
  public var header: String
  public var oldStart: Int
  public var oldCount: Int
  public var newStart: Int
  public var newCount: Int
  public var lines: [DiffLine]

  public init(
    header: String,
    oldStart: Int,
    oldCount: Int,
    newStart: Int,
    newCount: Int,
    lines: [DiffLine]
  ) {
    self.header = header
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
    self.lines = lines
  }
}

/// One line inside a hunk. `noNewlineMarker` corresponds to git's `\ No newline at end of file`.
public nonisolated struct DiffLine: Equatable, Codable, Sendable {
  public enum Kind: String, Equatable, Hashable, Codable, Sendable {
    case context
    case added
    case removed
    case noNewlineMarker
  }

  public var kind: Kind
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// A complete unified-diff output for a given scope.
public nonisolated struct UnifiedDiff: Equatable, Codable, Sendable {
  public var scope: DiffScope
  public var files: [FileChange]

  public init(scope: DiffScope, files: [FileChange]) {
    self.scope = scope
    self.files = files
  }
}

/// Result of `git status --porcelain=v1 -z`. Empty `entries` means a clean working tree.
public nonisolated struct WorkingTreeStatus: Equatable, Codable, Sendable {
  public struct Entry: Equatable, Hashable, Codable, Sendable {
    /// XY-style status as in porcelain-v1. Single-character codes: ` `, `M`, `A`, `D`, `R`, `C`,
    /// `U`, `?`, `!`. The index byte is the first character; the worktree byte is the second.
    public var indexStatus: Character
    public var worktreeStatus: Character
    public var path: String
    /// For renames/copies, the original path; nil otherwise.
    public var renamedFrom: String?

    public init(
      indexStatus: Character,
      worktreeStatus: Character,
      path: String,
      renamedFrom: String? = nil
    ) {
      self.indexStatus = indexStatus
      self.worktreeStatus = worktreeStatus
      self.path = path
      self.renamedFrom = renamedFrom
    }

    private enum CodingKeys: String, CodingKey {
      case indexStatus, worktreeStatus, path, renamedFrom
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.indexStatus = try Self.decodeChar(container, key: .indexStatus)
      self.worktreeStatus = try Self.decodeChar(container, key: .worktreeStatus)
      self.path = try container.decode(String.self, forKey: .path)
      self.renamedFrom = try container.decodeIfPresent(String.self, forKey: .renamedFrom)
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(String(indexStatus), forKey: .indexStatus)
      try container.encode(String(worktreeStatus), forKey: .worktreeStatus)
      try container.encode(path, forKey: .path)
      try container.encodeIfPresent(renamedFrom, forKey: .renamedFrom)
    }

    private static func decodeChar(
      _ container: KeyedDecodingContainer<CodingKeys>,
      key: CodingKeys
    ) throws -> Character {
      let raw = try container.decode(String.self, forKey: key)
      guard raw.count == 1, let first = raw.first else {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: container, debugDescription: "expected single character, got '\(raw)'"
        )
      }
      return first
    }
  }

  public var entries: [Entry]

  public init(entries: [Entry]) {
    self.entries = entries
  }

  public var isClean: Bool { entries.isEmpty }
}

/// Summed line counts for a worktree's uncommitted edits (`git diff HEAD
/// --shortstat`). Sidebar rows render this as `+additions −deletions` so
/// users can see "how much I've changed since the last commit" at a glance,
/// independent of whether a PR has been opened.
public nonisolated struct LocalDiffStats: Equatable, Codable, Sendable {
  /// Lines added in the working tree relative to HEAD. `0` when there are no
  /// uncommitted insertions.
  public let additions: Int
  /// Lines removed in the working tree relative to HEAD.
  public let deletions: Int

  public init(additions: Int, deletions: Int) {
    self.additions = additions
    self.deletions = deletions
  }
}

/// One branch known to the worktree. `shortName` is the user-facing form
/// (`main`, `feature/x`, `origin/main`); refs/heads/ and refs/remotes/ prefixes
/// are stripped before construction.
public nonisolated struct BranchRef: Equatable, Hashable, Sendable {
  public let shortName: String
  public let isRemote: Bool
  /// For local branches, the upstream's short name (e.g. `origin/main`); nil for
  /// untracked locals and for all remote-tracking refs.
  public let upstream: String?

  public init(shortName: String, isRemote: Bool, upstream: String?) {
    self.shortName = shortName
    self.isRemote = isRemote
    self.upstream = upstream
  }
}

/// Snapshot of all branches visible in a worktree. `current == nil` indicates
/// detached HEAD; `local` and `remote` may both be empty in a freshly
/// initialised repository.
public nonisolated struct BranchInventory: Equatable, Sendable {
  public let current: String?
  public let local: [BranchRef]
  public let remote: [BranchRef]

  public init(current: String?, local: [BranchRef], remote: [BranchRef]) {
    self.current = current
    self.local = local
    self.remote = remote
  }
}

/// Caller intent for a branch switch. `remoteTracking` means "check out this
/// remote ref"; the service layer decides whether to materialise a local
/// tracking branch.
public nonisolated enum BranchSwitchTarget: Equatable, Sendable {
  case local(name: String)
  case remoteTracking(shortName: String)
}
