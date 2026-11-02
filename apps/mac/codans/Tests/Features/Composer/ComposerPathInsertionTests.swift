import Foundation
import SwiftUI
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
    let web = [URL(string: "https://example.com/file")!]
    #expect(ComposerPathInsertion.insert(web, into: "keep", selection: nil) == nil)
  }
}

@MainActor
struct ComposerSelectionTests {
  @Test
  func editPassesTheSelectionAndPutsTheCaretAfterTheInsertedText() throws {
    guard #available(macOS 15, *) else { return }
    var text = "open FILE now"
    let selection = ComposerSelection()
    let start = text.index(text.startIndex, offsetBy: 5)
    let end = text.index(text.startIndex, offsetBy: 9)
    selection.textSelection = TextSelection(range: start..<end)

    var received: Range<Int>?
    selection.edit(text) { range in
      received = range
      text = "open '/tmp/a.txt' now"
      return text
    }

    #expect(received == 5..<9)
    guard case .selection(let caret) = try #require(selection.textSelection).indices else {
      Issue.record("expected a single selection")
      return
    }
    #expect(caret.isEmpty)
    #expect(text.utf16.distance(from: text.startIndex, to: caret.lowerBound) == 17)
  }

  @Test
  func noCaretPassesNilAndNilDoesNotClearARecordedCaret() {
    guard #available(macOS 15, *) else { return }
    let selection = ComposerSelection()
    var received: Range<Int>? = 0..<0
    selection.edit("abc") { range in
      received = range
      return "abc"
    }
    #expect(received == nil)

    let text = "abc"
    selection.textSelection = TextSelection(insertionPoint: text.endIndex)
    selection.textSelection = nil
    selection.edit(text) { range in
      received = range
      return text
    }
    #expect(received == 3..<3)
  }

  @Test
  func caretPastTheEndOfShorterTextCountsAsNoCaret() {
    guard #available(macOS 15, *) else { return }
    let long = "abcdef"
    let selection = ComposerSelection()
    selection.textSelection = TextSelection(insertionPoint: long.endIndex)
    var received: Range<Int>? = 0..<0
    selection.edit("ab") { range in
      received = range
      return "ab"
    }
    #expect(received == nil)
  }
}
