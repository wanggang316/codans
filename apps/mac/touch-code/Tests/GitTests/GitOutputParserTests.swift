import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

struct GitOutputParserTests {
  // MARK: - Log

  @Test
  func parseLogLinearTwoCommits() throws {
    // Field separator is NUL (\0). Record separator is also NUL (git log -z appends NUL
    // between records). The primer-style fixture: two commits, linear.
    let fixture =
      Self.logRecord(
        hash: "aaaaaaa1111111111111111111111111111111aa",
        authorName: "Gump",
        authorEmail: "gump@example.com",
        date: "2026-04-20T10:00:00+00:00",
        subject: "initial",
        parents: ""
      )
      + Self.logRecord(
        hash: "bbbbbbb2222222222222222222222222222222bb",
        authorName: "Claude",
        authorEmail: "claude@example.com",
        date: "2026-04-20T11:00:00+00:00",
        subject: "second",
        parents: "aaaaaaa1111111111111111111111111111111aa"
      )
    let commits = try GitOutputParser.parseLog(Data(fixture.utf8))
    #expect(commits.count == 2)
    #expect(commits[0].id == "aaaaaaa1111111111111111111111111111111aa")
    #expect(commits[0].authorName == "Gump")
    #expect(commits[0].parents.isEmpty)
    #expect(commits[1].subject == "second")
    #expect(commits[1].parents == ["aaaaaaa1111111111111111111111111111111aa"])
  }

  @Test
  func parseLogMergeCommitHasTwoParents() throws {
    let fixture = Self.logRecord(
      hash: "ccccccc3333333333333333333333333333333cc",
      authorName: "Gump",
      authorEmail: "gump@example.com",
      date: "2026-04-20T12:00:00+00:00",
      subject: "merge branches",
      parents: "aaaaaaa1 bbbbbbb2"
    )
    let commits = try GitOutputParser.parseLog(Data(fixture.utf8))
    #expect(commits.count == 1)
    #expect(commits[0].parents == ["aaaaaaa1", "bbbbbbb2"])
  }

  @Test
  func parseLogRootCommitHasNoParents() throws {
    let fixture = Self.logRecord(
      hash: "root000000000000000000000000000000000000",
      authorName: "Gump",
      authorEmail: "gump@example.com",
      date: "2026-04-20T09:00:00+00:00",
      subject: "root",
      parents: ""
    )
    let commits = try GitOutputParser.parseLog(Data(fixture.utf8))
    #expect(commits.count == 1)
    #expect(commits[0].parents.isEmpty)
  }

  @Test
  func parseLogHandlesUTF8AuthorNames() throws {
    let fixture = Self.logRecord(
      hash: "0123456789abcdef0123456789abcdef01234567",
      authorName: "王刚",
      authorEmail: "wg@example.com",
      date: "2026-04-20T10:00:00+00:00",
      subject: "non-latin subject — with em-dash",
      parents: ""
    )
    let commits = try GitOutputParser.parseLog(Data(fixture.utf8))
    #expect(commits.count == 1)
    #expect(commits[0].authorName == "王刚")
    #expect(commits[0].subject.contains("em-dash"))
  }

  @Test
  func parseLogEmptyInputReturnsEmpty() throws {
    let commits = try GitOutputParser.parseLog(Data())
    #expect(commits.isEmpty)
  }

  @Test
  func parseLogRejectsMalformedFieldCount() {
    // Three fields: not a multiple of 6.
    let fixture = "hash\0name\0email\0"
    #expect(throws: (any Error).self) {
      try GitOutputParser.parseLog(Data(fixture.utf8))
    }
  }

  // MARK: - Status

  @Test
  func parseStatusCleanIsEmpty() throws {
    let status = try GitOutputParser.parseStatus(Data())
    #expect(status.isClean)
  }

  @Test
  func parseStatusMixedEntries() throws {
    // `XY <path>\0` records. Here: modified unstaged, added staged, untracked.
    let fixture = " M src/file.swift\0A  src/new.swift\0?? scratch.txt\0"
    let status = try GitOutputParser.parseStatus(Data(fixture.utf8))
    #expect(status.entries.count == 3)
    #expect(status.entries[0].indexStatus == " ")
    #expect(status.entries[0].worktreeStatus == "M")
    #expect(status.entries[0].path == "src/file.swift")
    #expect(status.entries[1].indexStatus == "A")
    #expect(status.entries[1].path == "src/new.swift")
    #expect(status.entries[2].indexStatus == "?")
    #expect(status.entries[2].worktreeStatus == "?")
    #expect(status.entries[2].path == "scratch.txt")
  }

  @Test
  func parseStatusRenameCarriesOldPath() throws {
    // Porcelain-v1 -z emits rename as: "R  new\0old\0".
    let fixture = "R  new/path.swift\0old/path.swift\0"
    let status = try GitOutputParser.parseStatus(Data(fixture.utf8))
    #expect(status.entries.count == 1)
    let entry = status.entries[0]
    #expect(entry.indexStatus == "R")
    #expect(entry.path == "new/path.swift")
    #expect(entry.renamedFrom == "old/path.swift")
  }

  @Test
  func parseStatusUTF8Paths() throws {
    let fixture = "?? 日本語/ファイル.txt\0"
    let status = try GitOutputParser.parseStatus(Data(fixture.utf8))
    #expect(status.entries.count == 1)
    #expect(status.entries[0].path == "日本語/ファイル.txt")
  }

  // MARK: - helpers

  private static func logRecord(
    hash: String,
    authorName: String,
    authorEmail: String,
    date: String,
    subject: String,
    parents: String
  ) -> String {
    // Six NUL-separated fields + trailing NUL record terminator.
    return [hash, authorName, authorEmail, date, subject, parents].joined(separator: "\0") + "\0"
  }
}
