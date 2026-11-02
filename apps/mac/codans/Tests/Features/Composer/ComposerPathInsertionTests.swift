import Foundation
import Testing

@testable import Codans

@MainActor
struct ComposerPathInsertionTests {
  private static let files = [
    URL(fileURLWithPath: "/tmp/a.txt"),
    URL(fileURLWithPath: "/tmp/my file.txt"),
  ]
  private static let paths = "'/tmp/a.txt' '/tmp/my file.txt'"

  private func insert(_ text: String, _ selection: Range<Int>?) -> ComposerPathInsertion.Result? {
    ComposerPathInsertion.insert(Self.files, into: text, selection: selection)
  }

  @Test
  func caretAtStartAddsSpaceOnlyAfter() {
    let result = insert("review", 0..<0)
    let expected = Self.paths + " "
    #expect(result?.text == expected + "review")
    #expect(result?.selection == expected.utf16.count..<expected.utf16.count)
  }

  @Test
  func caretInsideWordAddsSpaceOnBothSides() {
    let result = insert("abcd", 2..<2)
    let inserted = " " + Self.paths + " "
    #expect(result?.text == "ab" + inserted + "cd")
    let caret = 2 + inserted.utf16.count
    #expect(result?.selection == caret..<caret)
  }

  @Test
  func caretNextToWhitespaceAddsNoSpace() {
    let result = insert("check  now", 6..<6)
    #expect(result?.text == "check " + Self.paths + " now")
    let caret = 6 + Self.paths.utf16.count
    #expect(result?.selection == caret..<caret)
  }

  @Test
  func caretAtEndAddsSpaceOnlyBefore() {
    let result = insert("review", 6..<6)
    #expect(result?.text == "review " + Self.paths)
    #expect(result?.selection == result.map { $0.text.utf16.count..<$0.text.utf16.count })
  }

  @Test
  func selectionIsReplaced() {
    let result = insert("open FILE now", 5..<9)
    #expect(result?.text == "open " + Self.paths + " now")
    let caret = 5 + Self.paths.utf16.count
    #expect(result?.selection == caret..<caret)
  }

  @Test
  func noCaretAppendsWithSpacingRule() {
    #expect(insert("review", nil)?.text == "review " + Self.paths)
    #expect(insert("review\n", nil)?.text == "review\n" + Self.paths)
    #expect(insert("", nil)?.text == Self.paths)
  }

  @Test
  func outOfRangeSelectionIsClamped() {
    #expect(insert("ab", 5..<9)?.text == "ab " + Self.paths)
  }

  @Test
  func offsetInsideSurrogatePairDoesNotSplitCharacter() {
    // "😀" is two UTF-16 units; offset 1 falls between them.
    let result = insert("😀x", 1..<1)
    #expect(result?.text == "😀 " + Self.paths + " x")
  }

  @Test
  func emptyAndNonFileSelectionsReturnNil() {
    #expect(ComposerPathInsertion.insert([], into: "keep", selection: 0..<0) == nil)
    #expect(
      ComposerPathInsertion.insert(
        [URL(string: "https://example.com/file")!], into: "keep", selection: nil) == nil)
  }
}
