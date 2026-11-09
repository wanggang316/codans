import CodansCore
import Observation
import SwiftUI

/// The caret or selection of a `ComposerTextEditor`, kept by the view that
/// owns the editor.
///
/// The value stays opaque while the user types. SwiftUI reports a new
/// selection before it writes the new text, so converting it at that time
/// would read indices of one string against another. It is converted only
/// when text is inserted. The selection API needs macOS 15; on macOS 14
/// there is no caret and insertions go at the end.
@MainActor
@Observable
final class ComposerSelection {
  /// Stored untyped because `TextSelection` needs macOS 15.
  private var value: Any?
  /// Counts reported carets, so a view can react to a caret move that does
  /// not change the text (a click, the arrow keys).
  private(set) var revision = 0

  /// `nil` until the editor reports a caret. Setting `nil` keeps the last
  /// one: focus leaving the editor (to open a file picker, for example)
  /// must not lose the place to insert at.
  @available(macOS 15, *)
  var textSelection: TextSelection? {
    get { value as? TextSelection }
    set {
      if let newValue {
        value = newValue
        revision &+= 1
      }
    }
  }

  /// Inserts picked file paths at the caret or selection of `text` by the
  /// shared rule. `send` gets the caret or selection as UTF-16 offsets
  /// (`nil` when there is none) and makes the reducer apply the same rule.
  /// The caret then goes after the inserted text, also when the new text
  /// equals the old one (a selection replaced by the same path).
  func insertPaths(_ urls: [URL], into text: String, send: (Range<Int>?) -> Void) {
    let range = utf16Range(in: text)
    guard let result = ComposerPathInsertion.insert(urls, into: text, selection: range) else { return }
    send(range)
    moveCaret(toUTF16Offset: result.selection.upperBound, in: result.text)
  }

  /// Puts the skill call `prefix` at the caret or selection of `text` by
  /// the Skills button's rule. `send` gets the caret or selection as UTF-16
  /// offsets and makes the reducer apply the same rule; the caret then goes
  /// after the prefix, so skill completion opens there.
  func insertSkillPrefix(
    _ prefix: Character, position: SkillInvocationPosition, into text: String,
    send: (Range<Int>?) -> Void
  ) {
    let range = utf16Range(in: text)
    guard
      let result = ComposerSkillCompletion.insertingPrefix(
        prefix, into: text, selection: range, position: position)
    else { return }
    send(range)
    moveCaret(toUTF16Offset: result.caret, in: result.text)
  }

  /// The caret in `text` as a UTF-16 offset for skill completion: the end
  /// of the text when the editor reports no caret (macOS 14), `nil` when a
  /// range is selected. Read it after the text changed, so both describe
  /// the same string.
  func completionCaret(in text: String) -> Int? {
    guard let range = utf16Range(in: text) else { return text.utf16.count }
    return range.isEmpty ? range.lowerBound : nil
  }

  private func utf16Range(in text: String) -> Range<Int>? {
    guard #available(macOS 15, *), let selection = textSelection else { return nil }
    let range: Range<String.Index>?
    switch selection.indices {
    case .selection(let value): range = value
    case .multiSelection(let set): range = set.ranges.first
    @unknown default: range = nil
    }
    // A selection from older text can point past the end of this one.
    guard let range, range.upperBound <= text.endIndex else { return nil }
    let utf16 = text.utf16
    let lower = utf16.distance(from: utf16.startIndex, to: range.lowerBound)
    let upper = utf16.distance(from: utf16.startIndex, to: range.upperBound)
    return lower..<upper
  }

  func moveCaret(toUTF16Offset offset: Int, in text: String) {
    guard #available(macOS 15, *) else { return }
    let utf16 = text.utf16
    let index = utf16.index(utf16.startIndex, offsetBy: min(max(offset, 0), utf16.count))
    textSelection = TextSelection(insertionPoint: index)
  }
}

/// `TextEditor` that records its caret or selection in a `ComposerSelection`,
/// so picked file paths can go where the user is typing.
struct ComposerTextEditor: View {
  @Binding var text: String
  let selection: ComposerSelection

  var body: some View {
    if #available(macOS 15, *) {
      TextEditor(text: $text, selection: textSelection)
    } else {
      TextEditor(text: $text)
    }
  }

  @available(macOS 15, *)
  private var textSelection: Binding<TextSelection?> {
    Binding(
      get: { selection.textSelection },
      set: { selection.textSelection = $0 },
    )
  }
}
