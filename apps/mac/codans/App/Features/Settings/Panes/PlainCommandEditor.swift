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

  /// Whether the text view should grab first responder as soon as it attaches
  /// to its window. Needed inside a `.popover` (the click that opens the
  /// popover never reaches the field, so it would otherwise be unfocusable),
  /// but wrong for inline use: when several editors render at once they would
  /// race for first responder and the last one created wins — e.g. the three
  /// lifecycle editors in Project → General all stealing focus to the last
  /// (Delete) script on open. Defaults to off; only the popover opts in.
  var autoFocusOnAppear: Bool = false

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
    // Opt-in only: inline editors leave focus to the user's click so they don't
    // hijack the caret on appear (see `autoFocusOnAppear`).
    if autoFocusOnAppear {
      context.coordinator.focusWhenAttached(textView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    // Refresh the coordinator's binding every update — and BEFORE the
    // first-responder early-return below. The binding's setter closes over the
    // parent `script`, which is replaced when the user flips the target segment
    // (or any other field). `makeCoordinator` captured the binding only once,
    // so without this `textDidChange` would write through a stale `script` and
    // a keystroke would revert the just-changed segment back to its old value.
    context.coordinator.text = $text
    // While the user is actively editing (the text view is first responder),
    // never push the binding back into the view. The binding round-trips a
    // keystroke behind (type → textDidChange → store → re-render → here), so
    // re-assigning `string` mid-edit reset the contents and yanked the caret
    // to the start on every character. The text view is the source of truth
    // while focused; outward sync still flows through `textDidChange`.
    if textView.window?.firstResponder === textView { return }
    // Unfocused: apply genuine external changes (e.g. the parent reset the
    // draft), keeping the caret position as close as possible.
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
    /// A plain, re-assignable binding (NOT `@Binding`): the wrapped binding
    /// closes over the parent's `script`, which is replaced on every edit, so
    /// `updateNSView` refreshes this to the latest one. Writing through a stale
    /// binding would carry an outdated `script` and undo sibling-field changes.
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }

    /// Makes `textView` first responder as soon as it joins a window. Hops the
    /// run loop until the window exists (the popover attaches a few ticks after
    /// `makeNSView`), capped so a never-attached view can't spin forever.
    func focusWhenAttached(_ textView: NSTextView, attempt: Int = 0) {
      guard attempt < 12 else { return }
      DispatchQueue.main.async { [weak textView] in
        guard let textView else { return }
        guard let window = textView.window else {
          self.focusWhenAttached(textView, attempt: attempt + 1)
          return
        }
        // The popover window isn't key the instant it appears. First responder
        // alone then leaves the insertion point un-drawn until the first
        // keystroke — and the first click gets swallowed by window activation
        // instead of reaching the text view. Make the window key, take first
        // responder, and kick the insertion-point timer so the caret shows on
        // open and a later click lands in an already-key window.
        window.makeKey()
        window.makeFirstResponder(textView)
        textView.updateInsertionPointStateAndRestartTimer(true)
      }
    }
  }
}
