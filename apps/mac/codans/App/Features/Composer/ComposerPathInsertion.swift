import CodansCore
import Foundation

/// Inserts picked file paths into a composer's text. Shared by the Command
/// Queue and New Agent composers so both follow one rule.
///
/// Positions are UTF-16 offsets: they come from and go back to the text
/// view, and `String.Index` values do not stay valid across edits.
enum ComposerPathInsertion {
  struct Result: Equatable {
    var text: String
    /// Empty range at the end of the inserted text.
    var selection: Range<Int>
  }

  /// Shell-quotes each file URL's path and joins them with spaces. Puts the
  /// result in place of `selection`, or at the end when there is no recorded
  /// caret. A space is added on a side whose neighbor is not whitespace.
  /// Returns `nil` when no file URL is given, so the text stays unchanged.
  static func insert(_ urls: [URL], into text: String, selection: Range<Int>?) -> Result? {
    let paths = urls.filter(\.isFileURL)
      .map { ShellQuoting.quoted($0.path(percentEncoded: false)) }
      .joined(separator: " ")
    guard !paths.isEmpty else { return nil }

    let utf16 = text.utf16
    let range = selection.map(clamped(to: utf16.count)) ?? utf16.count..<utf16.count
    // A selection grows to whole characters; a bare caret moves forward.
    let upper = text.characterBoundary(atUTF16Offset: range.upperBound, roundingDown: false)
    let lower =
      range.isEmpty
      ? upper : text.characterBoundary(atUTF16Offset: range.lowerBound, roundingDown: true)

    var inserted = paths
    if let before = text[..<lower].last, !before.isWhitespace {
      inserted = " " + inserted
    }
    if let after = text[upper...].first, !after.isWhitespace {
      inserted += " "
    }
    var result = text
    result.replaceSubrange(lower..<upper, with: inserted)
    let caret = utf16.distance(from: utf16.startIndex, to: lower) + inserted.utf16.count
    return Result(text: result, selection: caret..<caret)
  }

  private static func clamped(to count: Int) -> (Range<Int>) -> Range<Int> {
    { range in
      let lower = min(max(range.lowerBound, 0), count)
      let upper = min(max(range.upperBound, lower), count)
      return lower..<upper
    }
  }
}

extension String {
  /// The character boundary at or next to a UTF-16 offset, so an offset that
  /// falls inside a surrogate pair or a grapheme cluster cannot split it.
  fileprivate func characterBoundary(atUTF16Offset offset: Int, roundingDown: Bool) -> Index {
    let index = utf16.index(utf16.startIndex, offsetBy: offset)
    if let aligned = index.samePosition(in: self) { return aligned }
    return roundingDown
      ? indices.last { $0 < index } ?? startIndex
      : indices.first { $0 > index } ?? endIndex
  }
}
