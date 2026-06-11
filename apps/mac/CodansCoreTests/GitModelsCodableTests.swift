import Foundation
import Testing

@testable import CodansCore

struct GitModelsCodableTests {
  // MARK: - Commit / shortID

  @Test
  func commitShortIDDerivedFromSHA1() {
    let commit = Self.makeCommit(id: "0123456789abcdef0123456789abcdef01234567")
    #expect(commit.shortID == "0123456")
    #expect(commit.shortID.count == 7)
  }

  @Test
  func commitShortIDDerivedFromSHA256() {
    let sha256 = String(repeating: "a", count: 64)
    let commit = Self.makeCommit(id: sha256)
    #expect(commit.shortID == "aaaaaaa")
    #expect(commit.shortID.count == 7)
  }

  @Test
  func commitRoundTrip() throws {
    let commit = Self.makeCommit(id: "abc1234def5678")
    let decoded = try Self.roundTrip(commit)
    #expect(decoded == commit)
    #expect(decoded.shortID == commit.shortID)
  }

  // MARK: - FileChange.Kind

  @Test
  func fileChangeKindAddedRoundTrip() throws {
    let change = FileChange(id: "new.swift", kind: .added, isBinary: false, linesAdded: 10, linesRemoved: 0, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
  }

  @Test
  func fileChangeKindDeletedRoundTrip() throws {
    let change = FileChange(id: "old.swift", kind: .deleted, isBinary: false, linesAdded: 0, linesRemoved: 42, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
  }

  @Test
  func fileChangeKindModifiedRoundTrip() throws {
    let change = FileChange(id: "x.swift", kind: .modified, isBinary: false, linesAdded: 3, linesRemoved: 2, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
  }

  @Test
  func fileChangeKindRenamedPreservesFromPath() throws {
    let change = FileChange(id: "new/path.swift", kind: .renamed(from: "old/path.swift"),
                            isBinary: false, linesAdded: 1, linesRemoved: 1, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
    if case .renamed(let from) = decoded.kind {
      #expect(from == "old/path.swift")
    } else {
      Issue.record("expected .renamed, got \(decoded.kind)")
    }
  }

  @Test
  func fileChangeKindCopiedPreservesFromPath() throws {
    let change = FileChange(id: "copy.swift", kind: .copied(from: "original.swift"),
                            isBinary: false, linesAdded: 0, linesRemoved: 0, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
  }

  @Test
  func fileChangeKindTypeChangedRoundTrip() throws {
    let change = FileChange(id: "link", kind: .typeChanged, isBinary: false,
                            linesAdded: 0, linesRemoved: 0, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
  }

  @Test
  func fileChangeBinaryFlagRoundTrip() throws {
    let change = FileChange(id: "logo.png", kind: .modified, isBinary: true,
                            linesAdded: 0, linesRemoved: 0, hunks: [])
    let decoded = try Self.roundTrip(change)
    #expect(decoded == change)
    #expect(decoded.isBinary)
  }

  // MARK: - DiffHunk + DiffLine

  @Test
  func diffLineKindsRoundTrip() throws {
    let hunk = DiffHunk(
      header: "@@ -1,3 +1,4 @@",
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 4,
      lines: [
        DiffLine(kind: .context, text: " unchanged"),
        DiffLine(kind: .added, text: "+added"),
        DiffLine(kind: .removed, text: "-removed"),
        DiffLine(kind: .noNewlineMarker, text: "\\ No newline at end of file"),
      ]
    )
    let decoded = try Self.roundTrip(hunk)
    #expect(decoded == hunk)
    #expect(decoded.lines.count == 4)
    #expect(decoded.lines[0].kind == .context)
    #expect(decoded.lines[1].kind == .added)
    #expect(decoded.lines[2].kind == .removed)
    #expect(decoded.lines[3].kind == .noNewlineMarker)
  }

  // MARK: - UnifiedDiff + DiffScope

  @Test
  func unifiedDiffWorkingScopeRoundTrip() throws {
    let diff = UnifiedDiff(scope: .working, files: [])
    let decoded = try Self.roundTrip(diff)
    #expect(decoded == diff)
    #expect(decoded.scope == .working)
  }

  @Test
  func unifiedDiffCommitScopeRoundTrip() throws {
    let diff = UnifiedDiff(scope: .commit(sha: "deadbee"), files: [])
    let decoded = try Self.roundTrip(diff)
    #expect(decoded == diff)
    if case .commit(let sha) = decoded.scope {
      #expect(sha == "deadbee")
    } else {
      Issue.record("expected .commit, got \(decoded.scope)")
    }
  }

  @Test
  func diffScopeAllVariantsRoundTrip() throws {
    let scopes: [DiffScope] = [.working, .staged, .log, .commit(sha: "abc1234")]
    for scope in scopes {
      let decoded = try Self.roundTrip(scope)
      #expect(decoded == scope)
    }
  }

  // MARK: - LogPage + merge / root commits

  @Test
  func logPageMergeCommitHasTwoParents() throws {
    let merge = Self.makeCommit(id: "merge000", parents: ["parent1", "parent2"])
    let page = LogPage(cursor: .init(offset: 0, limit: 10), commits: [merge], hasMore: false)
    let decoded = try Self.roundTrip(page)
    #expect(decoded == page)
    #expect(decoded.commits[0].parents.count == 2)
  }

  @Test
  func logPageRootCommitHasZeroParents() throws {
    let root = Self.makeCommit(id: "root0000", parents: [])
    let page = LogPage(cursor: .init(offset: 0, limit: 10), commits: [root], hasMore: false)
    let decoded = try Self.roundTrip(page)
    #expect(decoded == page)
    #expect(decoded.commits[0].parents.isEmpty)
  }

  @Test
  func logPagePaginationRoundTrip() throws {
    let cursor = LogPage.Cursor(offset: 100, limit: 100)
    let page = LogPage(cursor: cursor, commits: [], hasMore: true)
    let decoded = try Self.roundTrip(page)
    #expect(decoded == page)
    #expect(decoded.cursor.offset == 100)
    #expect(decoded.hasMore)
  }

  // MARK: - WorkingTreeStatus

  @Test
  func workingTreeStatusCleanByDefault() {
    let status = WorkingTreeStatus(entries: [])
    #expect(status.isClean)
  }

  @Test
  func workingTreeStatusNotCleanWithEntries() {
    let entry = WorkingTreeStatus.Entry(indexStatus: "M", worktreeStatus: " ", path: "x.swift")
    let status = WorkingTreeStatus(entries: [entry])
    #expect(!status.isClean)
  }

  @Test
  func workingTreeStatusEntryRoundTrip() throws {
    let entry = WorkingTreeStatus.Entry(
      indexStatus: "R", worktreeStatus: " ", path: "new/path", renamedFrom: "old/path"
    )
    let decoded = try Self.roundTrip(entry)
    #expect(decoded == entry)
    #expect(decoded.indexStatus == "R")
    #expect(decoded.renamedFrom == "old/path")
  }

  @Test
  func workingTreeStatusUTF8PathRoundTrip() throws {
    let entry = WorkingTreeStatus.Entry(
      indexStatus: "?", worktreeStatus: "?", path: "日本語/ファイル.txt"
    )
    let status = WorkingTreeStatus(entries: [entry])
    let decoded = try Self.roundTrip(status)
    #expect(decoded == status)
  }

  // MARK: - Helpers

  private static func makeCommit(
    id: String,
    parents: [String] = ["parent"]
  ) -> Commit {
    Commit(
      id: id,
      authorName: "Gump",
      authorEmail: "gump@example.com",
      date: Date(timeIntervalSince1970: 1_700_000_000),
      subject: "test commit",
      parents: parents
    )
  }

  private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
