import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

struct DiffParserTests {
  @Test
  func emptyInputReturnsEmptyDiff() throws {
    let diff = try DiffParser.parse(Data(), scope: .working)
    #expect(diff.files.isEmpty)
    #expect(diff.scope == .working)
  }

  @Test
  func addedFileIsClassifiedCorrectly() throws {
    let fixture = """
      diff --git a/new.swift b/new.swift
      new file mode 100644
      index 0000000..e69de29
      --- /dev/null
      +++ b/new.swift
      @@ -0,0 +1,2 @@
      +line one
      +line two
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.id == "new.swift")
    #expect(file.kind == .added)
    #expect(file.linesAdded == 2)
    #expect(file.linesRemoved == 0)
    #expect(file.hunks.count == 1)
    #expect(file.hunks[0].lines.map(\.kind) == [.added, .added])
  }

  @Test
  func deletedFileIsClassifiedCorrectly() throws {
    let fixture = """
      diff --git a/old.swift b/old.swift
      deleted file mode 100644
      index e69de29..0000000
      --- a/old.swift
      +++ /dev/null
      @@ -1,2 +0,0 @@
      -line one
      -line two
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.id == "old.swift")  // pre-image path for deletion
    #expect(file.kind == .deleted)
    #expect(file.linesRemoved == 2)
    #expect(file.linesAdded == 0)
  }

  @Test
  func modifiedFileRetainsContextAddedRemovedLines() throws {
    let fixture = """
      diff --git a/x.swift b/x.swift
      index abc1234..def5678 100644
      --- a/x.swift
      +++ b/x.swift
      @@ -1,3 +1,4 @@
       context line 1
      -removed line
      +added line 1
      +added line 2
       context line 2
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.kind == .modified)
    #expect(file.linesAdded == 2)
    #expect(file.linesRemoved == 1)
    #expect(file.hunks.count == 1)
    let hunk = file.hunks[0]
    #expect(hunk.oldStart == 1)
    #expect(hunk.oldCount == 3)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 4)
    let markers = hunk.lines.map(\.kind)
    #expect(markers == [.context, .removed, .added, .added, .context])
  }

  @Test
  func renameWithContentChangePreservesFromPath() throws {
    let fixture = """
      diff --git a/old/path.swift b/new/path.swift
      similarity index 80%
      rename from old/path.swift
      rename to new/path.swift
      index abc1234..def5678 100644
      --- a/old/path.swift
      +++ b/new/path.swift
      @@ -1 +1 @@
      -old content
      +new content
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.id == "new/path.swift")
    if case .renamed(let from) = file.kind {
      #expect(from == "old/path.swift")
    } else {
      Issue.record("expected .renamed, got \(file.kind)")
    }
    #expect(file.linesAdded == 1)
    #expect(file.linesRemoved == 1)
  }

  @Test
  func copiedFilePreservesFromPath() throws {
    let fixture = """
      diff --git a/original.swift b/copy.swift
      similarity index 100%
      copy from original.swift
      copy to copy.swift
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.id == "copy.swift")
    if case .copied(let from) = file.kind {
      #expect(from == "original.swift")
    } else {
      Issue.record("expected .copied, got \(file.kind)")
    }
  }

  @Test
  func binaryFileMarkedWithoutHunks() throws {
    let fixture = """
      diff --git a/logo.png b/logo.png
      index abc1234..def5678 100644
      Binary files a/logo.png and b/logo.png differ
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.isBinary)
    #expect(file.hunks.isEmpty)
    #expect(file.linesAdded == 0)
    #expect(file.linesRemoved == 0)
  }

  @Test
  func modeOnlyChangeIsTypeChanged() throws {
    let fixture = """
      diff --git a/script.sh b/script.sh
      old mode 100644
      new mode 100755
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.kind == .typeChanged)
    #expect(file.hunks.isEmpty)
  }

  @Test
  func emptyNewFileHasNoHunks() throws {
    let fixture = """
      diff --git a/empty.txt b/empty.txt
      new file mode 100644
      index 0000000..e69de29
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 1)
    let file = diff.files[0]
    #expect(file.kind == .added)
    #expect(file.hunks.isEmpty)
  }

  @Test
  func noNewlineAtEOFMarkerPreserved() throws {
    let fixture = """
      diff --git a/file b/file
      index abc1234..def5678 100644
      --- a/file
      +++ b/file
      @@ -1 +1 @@
      -old content
      \\ No newline at end of file
      +new content
      \\ No newline at end of file
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    let file = diff.files[0]
    let markers = file.hunks[0].lines.map(\.kind)
    #expect(markers.contains(.noNewlineMarker))
  }

  @Test
  func multipleFilesInSingleDiff() throws {
    let fixture = """
      diff --git a/a.swift b/a.swift
      index 111..222 100644
      --- a/a.swift
      +++ b/a.swift
      @@ -1 +1 @@
      -old a
      +new a
      diff --git a/b.swift b/b.swift
      index 333..444 100644
      --- a/b.swift
      +++ b/b.swift
      @@ -1 +1 @@
      -old b
      +new b
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    #expect(diff.files.count == 2)
    #expect(diff.files[0].id == "a.swift")
    #expect(diff.files[1].id == "b.swift")
  }

  @Test
  func hunkHeaderWithoutCountDefaultsToOne() throws {
    let fixture = """
      diff --git a/x b/x
      index 1..2 100644
      --- a/x
      +++ b/x
      @@ -1 +1 @@
      -a
      +b
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    let hunk = diff.files[0].hunks[0]
    #expect(hunk.oldStart == 1)
    #expect(hunk.oldCount == 1)
    #expect(hunk.newStart == 1)
    #expect(hunk.newCount == 1)
  }

  @Test
  func hunkHeaderWithSectionHintPreservedInHeader() throws {
    let fixture = """
      diff --git a/x.swift b/x.swift
      index 1..2 100644
      --- a/x.swift
      +++ b/x.swift
      @@ -10,3 +10,3 @@ func example() {
       line a
      -line b
      +line B
      """
    let diff = try DiffParser.parse(Data(fixture.utf8), scope: .working)
    let hunk = diff.files[0].hunks[0]
    #expect(hunk.header.contains("func example()"))
  }

  @Test
  func diffTooLargeThrowsAfterCap() {
    // Build a synthetic diff with > 50_000 body lines.
    let linesPerFile = DiffParser.maxDiffLines + 1
    var fixture = """
      diff --git a/big.txt b/big.txt
      index 1..2 100644
      --- a/big.txt
      +++ b/big.txt
      @@ -1,\(linesPerFile) +1,\(linesPerFile) @@
      """
    for idx in 1...linesPerFile {
      fixture += "\n+added \(idx)"
    }
    let data = Data(fixture.utf8)
    #expect(throws: GitError.diffTooLarge) {
      try DiffParser.parse(data, scope: .working)
    }
  }
}
