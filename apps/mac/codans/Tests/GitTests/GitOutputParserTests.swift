import Foundation
import Testing
import CodansCore

@testable import Codans

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

// MARK: - Branch inventory

struct GitOutputParserBranchInventoryTests {
  @Test
  func parseBranchInventoryEmptyInputReturnsEmpty() throws {
    let inv = try GitOutputParser.parseBranchInventory(Data())
    #expect(inv.current == nil)
    #expect(inv.local.isEmpty)
    #expect(inv.remote.isEmpty)
  }

  @Test
  func parseBranchInventorySingleLocalMarkedCurrent() throws {
    let fixture = "refs/heads/main\tmain\torigin/main\t*\n"
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.current == "main")
    #expect(inv.local == [BranchRef(shortName: "main", isRemote: false, upstream: "origin/main")])
    #expect(inv.remote.isEmpty)
  }

  @Test
  func parseBranchInventoryMixedLocalAndRemoteSortedAndPinned() throws {
    let fixture = """
      refs/heads/main\tmain\t\t \n\
      refs/heads/feat/x\tfeat/x\t\t*\n\
      refs/heads/bugfix/y\tbugfix/y\t\t \n\
      refs/remotes/origin/main\torigin/main\t\t \n\
      refs/remotes/origin/feat/x\torigin/feat/x\t\t \n
      """
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.current == "feat/x")
    #expect(inv.local.map(\.shortName) == ["feat/x", "bugfix/y", "main"])
    #expect(inv.local.allSatisfy { $0.isRemote == false })
    #expect(inv.local.allSatisfy { $0.upstream == nil })
    #expect(inv.remote.map(\.shortName) == ["origin/feat/x", "origin/main"])
    #expect(inv.remote.allSatisfy { $0.isRemote })
    #expect(inv.remote.allSatisfy { $0.upstream == nil })
  }

  @Test
  func parseBranchInventoryFiltersOriginHEAD() throws {
    let fixture = """
      refs/remotes/origin/HEAD\torigin/HEAD\torigin/main\t \n\
      refs/remotes/origin/main\torigin/main\t\t \n
      """
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.remote.count == 1)
    #expect(inv.remote[0].shortName == "origin/main")
  }

  @Test
  func parseBranchInventoryDropsBareRemoteShortName() throws {
    // Edge: a remote record without a branch segment (`refs/remotes/origin`
    // → short `origin`). git shouldn't emit this in practice but the parser
    // is defensive: a true remote-tracking ref always has the shape
    // `<remote>/<branch>`, so a bare short name with no `/` is dropped.
    let fixture = """
      refs/remotes/origin\torigin\t\t \n\
      refs/remotes/origin/main\torigin/main\t\t \n
      """
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.remote.map(\.shortName) == ["origin/main"])
  }

  @Test
  func parseBranchInventoryRemoteUpstreamForcedToNilEvenIfPresent() throws {
    // git shouldn't emit an upstream for refs/remotes/, but the contract says
    // we drop it defensively if it appears. Lock that behaviour.
    let fixture = "refs/remotes/origin/main\torigin/main\torigin/main\t \n"
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.remote == [BranchRef(shortName: "origin/main", isRemote: true, upstream: nil)])
  }

  @Test
  func parseBranchInventoryLocalNamedHEADIsKept() throws {
    let fixture = "refs/heads/feature/HEAD\tfeature/HEAD\t\t \n"
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.local.map(\.shortName) == ["feature/HEAD"])
    #expect(inv.remote.isEmpty)
  }

  @Test
  func parseBranchInventoryDetachedHEADHasNilCurrent() throws {
    let fixture = """
      refs/heads/main\tmain\t\t \n\
      refs/heads/feat/x\tfeat/x\t\t \n\
      refs/remotes/origin/main\torigin/main\t\t \n
      """
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.current == nil)
    #expect(inv.local.map(\.shortName) == ["feat/x", "main"])
    #expect(inv.remote.map(\.shortName) == ["origin/main"])
  }

  @Test
  func parseBranchInventoryUnbornHEADUntrackedLocalCanonicalizesEmptyUpstreamToNil() throws {
    let fixture = "refs/heads/main\tmain\t\t*\n"
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.current == "main")
    #expect(inv.local.count == 1)
    #expect(inv.local[0].upstream == nil)
  }

  @Test
  func parseBranchInventoryUTF8BranchNames() throws {
    let fixture = """
      refs/heads/特性\t特性\t\t \n\
      refs/heads/🌱\t🌱\t\t \n
      """
    let inv = try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    #expect(inv.local.map(\.shortName).sorted() == ["特性", "🌱"].sorted())
  }

  @Test
  func parseBranchInventoryNonUTF8Throws() {
    // Stray 0xFF byte makes the buffer invalid UTF-8.
    var bytes = Data("refs/heads/main\tmain\t\t \n".utf8)
    bytes.append(0xFF)
    #expect(throws: GitError.self) {
      try GitOutputParser.parseBranchInventory(bytes)
    }
  }

  @Test
  func parseBranchInventoryMalformedRecordThrows() {
    // Only three TAB-separated fields — missing HEAD marker.
    let fixture = "refs/heads/main\tmain\torigin/main\n"
    #expect(throws: GitError.self) {
      try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    }
  }

  @Test
  func parseBranchInventoryMultipleCurrentMarkersThrows() {
    let fixture = """
      refs/heads/main\tmain\t\t*\n\
      refs/heads/feat/x\tfeat/x\t\t*\n
      """
    #expect(throws: GitError.self) {
      try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    }
  }

  @Test
  func parseBranchInventoryUnknownPrefixThrows() {
    let fixture = "refs/tags/v1\tv1\t\t \n"
    #expect(throws: GitError.self) {
      try GitOutputParser.parseBranchInventory(Data(fixture.utf8))
    }
  }
}
