import SwiftUI

/// `TextEditor` that reports its caret or selection as UTF-16 offsets, so a
/// reducer can insert text where the user is typing.
///
/// The selection API needs macOS 15. On macOS 14 this is a plain editor and
/// `selection` stays `nil`, so insertions go at the end.
struct ComposerTextEditor: View {
  @Binding var text: String
  /// Last caret or selection. The editor writes it as the user moves the
  /// caret; writing a new value moves the caret there.
  @Binding var selection: Range<Int>?

  var body: some View {
    if #available(macOS 15, *) {
      TextEditor(text: $text, selection: textSelection)
    } else {
      TextEditor(text: $text)
    }
  }

  @available(macOS 15, *)
  private var textSelection: Binding<TextSelection?> {
    Binding {
      selection.map { range in
        let utf16 = text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: min(range.lowerBound, utf16.count))
        let upper = utf16.index(utf16.startIndex, offsetBy: min(range.upperBound, utf16.count))
        return TextSelection(range: lower..<max(lower, upper))
      }
    } set: { newValue in
      // A `nil` (focus left the editor) keeps the last caret, so a file
      // picker opened from a button still inserts where the user was.
      guard let newValue else { return }
      let utf16 = text.utf16
      let range: Range<String.Index>?
      switch newValue.indices {
      case .selection(let value): range = value
      case .multiSelection(let set): range = set.ranges.first
      @unknown default: range = nil
      }
      guard let range else { return }
      let lower = utf16.distance(from: utf16.startIndex, to: range.lowerBound)
      let upper = utf16.distance(from: utf16.startIndex, to: range.upperBound)
      let offsets = lower..<max(lower, upper)
      if offsets != selection { selection = offsets }
    }
  }
}
