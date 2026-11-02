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

  /// `nil` until the editor reports a caret. Setting `nil` keeps the last
  /// one: focus leaving the editor (to open a file picker, for example)
  /// must not lose the place to insert at.
  @available(macOS 15, *)
  var textSelection: TextSelection? {
    get { value as? TextSelection }
    set { if let newValue { value = newValue } }
  }

  /// Runs `edit` with the caret or selection as UTF-16 offsets into
  /// `text()`, or `nil` when there is none, then puts the caret after the
  /// edited range. Text after the selection is unchanged by an insertion,
  /// so the caret goes in front of that text.
  func edit(_ text: () -> String, _ edit: (Range<Int>?) -> Void) {
    let before = text()
    let range = utf16Range(in: before)
    edit(range)
    let after = text()
    guard after != before else { return }
    let suffix = before.utf16.count - (range?.upperBound ?? before.utf16.count)
    moveCaret(toUTF16Offset: after.utf16.count - suffix, in: after)
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
    return utf16.distance(from: utf16.startIndex, to: range.lowerBound)
      ..< utf16.distance(from: utf16.startIndex, to: range.upperBound)
  }

  private func moveCaret(toUTF16Offset offset: Int, in text: String) {
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
