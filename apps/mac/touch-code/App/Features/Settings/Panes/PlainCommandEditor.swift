import AppKit
import SwiftUI

/// Multi-line plain-text editor for shell command fields. Wraps an
/// `NSTextView` because SwiftUI's `TextEditor` does not expose a
/// modifier to disable macOS's automatic substitutions — typing `"` or
/// `'` would otherwise produce typographic curly quotes that the shell
/// cannot parse, em-dashes for `--`, and so on.
///
/// Every substitution that touches the typed string is disabled here:
/// quote / dash / text-replacement / spelling correction / smart
/// insert-delete / data + link detection. Rich text is also off so a
/// paste from a styled source comes in as plain UTF-8.
struct PlainCommandEditor: NSViewRepresentable {
  @Binding var text: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    guard let textView = scrollView.documentView as? NSTextView else {
      return scrollView
    }
    textView.delegate = context.coordinator
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = .monospacedSystemFont(
      ofSize: NSFont.systemFontSize, weight: .regular
    )
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 4, height: 4)
    textView.string = text
    // An NSTextView embedded in a SwiftUI `.popover` does not reliably take
    // first responder from a click: at the moment the popover opens its window
    // is not yet key, so the click never installs a caret and the field reads
    // as unfocusable. Promote it to first responder once it has attached to the
    // popover window — same "wait for window, then focus" shape the pane-focus
    // paths use. Retries because the window is nil for the first run-loop ticks.
    context.coordinator.focusWhenAttached(textView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    // Avoid clobbering the user's selection / typing while they are
    // editing — only push upstream changes back into the view when the
    // text genuinely differs (e.g. the parent reset the draft).
    if textView.string != text {
      let selection = textView.selectedRange()
      textView.string = text
      let length = (text as NSString).length
      let clamped = NSRange(
        location: min(selection.location, length),
        length: 0
      )
      textView.setSelectedRange(clamped)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String

    init(text: Binding<String>) {
      self._text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
    }

    /// Makes `textView` first responder as soon as it joins a window. Hops the
    /// run loop until the window exists (the popover attaches a few ticks after
    /// `makeNSView`), capped so a never-attached view can't spin forever.
    func focusWhenAttached(_ textView: NSTextView, attempt: Int = 0) {
      guard attempt < 10 else { return }
      DispatchQueue.main.async { [weak textView] in
        guard let textView else { return }
        if let window = textView.window {
          window.makeFirstResponder(textView)
        } else {
          self.focusWhenAttached(textView, attempt: attempt + 1)
        }
      }
    }
  }
}
