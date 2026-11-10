import AppKit
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct ComposerTextEditorTests {
  private static let noReplacement = NSRange(location: NSNotFound, length: 0)

  @Test func textAnInputMethodComposesCountsAsMarkedTextUntilItIsConfirmed() async throws {
    let harness = try Harness()
    #expect(!harness.selection.hasMarkedText)

    harness.compose("a")
    #expect(harness.selection.hasMarkedText)

    harness.textView.insertText("啊", replacementRange: Self.noReplacement)
    await harness.settle()
    #expect(!harness.selection.hasMarkedText)
  }

  @Test func placeholderHidesWhileAnInputMethodComposes() async throws {
    let harness = try Harness()
    #expect(harness.showsPlaceholder)

    harness.compose("a")
    await harness.settle()
    // Hiding the placeholder must not make the editor drop the composition.
    #expect(harness.textView.hasMarkedText())
    #expect(!harness.showsPlaceholder)

    harness.compose("")
    await harness.settle()
    #expect(harness.showsPlaceholder)
  }

  @Test func cancelledCompositionLeavesNoMarkedText() async throws {
    let harness = try Harness()
    harness.compose("a")
    harness.compose("")
    await harness.settle()
    #expect(!harness.textView.hasMarkedText())
    #expect(!harness.selection.hasMarkedText)
  }

  @Test func anotherTextViewInTheWindowDoesNotReport() async throws {
    let harness = try Harness()
    let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    harness.container.addSubview(other)

    other.setMarkedText(
      "a", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    await harness.settle()
    #expect(other.hasMarkedText())
    #expect(!harness.selection.hasMarkedText)
  }

  private struct Editor: View {
    @State private var text = ""
    let selection: ComposerSelection

    var body: some View {
      ComposerTextEditor(text: $text, selection: selection, placeholder: "A placeholder that is wider than a few letters")
    }
  }

  @MainActor
  private final class Harness {
    let selection = ComposerSelection()
    let window: NSWindow
    /// The editor is in the top part; the bottom part is free.
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    let textView: NSTextView
    private let host: NSHostingView<Editor>

    init() throws {
      window = NSWindow(
        contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = container
      host = NSHostingView(rootView: Editor(selection: selection))
      host.frame = NSRect(x: 0, y: 180, width: 300, height: 120)
      container.addSubview(host)
      host.layoutSubtreeIfNeeded()
      textView = try #require(Self.textView(in: host))
      window.makeFirstResponder(textView)
    }

    /// The placeholder is much wider than the composed text, so it shows
    /// as drawn pixels in the right part of the first line.
    var showsPlaceholder: Bool {
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let scale = bitmap.pixelsWide / Int(host.bounds.width)
      let background = bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)
      for y in 0..<(24 * scale) {
        for x in (100 * scale)..<(200 * scale) where bitmap.colorAt(x: x, y: y) != background {
          return true
        }
      }
      return false
    }

    /// Waits for the work the editor queued on the main queue.
    func settle() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }

    /// Sets the marked text as an input method does while the user types.
    func compose(_ marked: String) {
      textView.setMarkedText(
        marked,
        selectedRange: NSRange(location: marked.utf16.count, length: 0),
        replacementRange: ComposerTextEditorTests.noReplacement)
    }

    private static func textView(in view: NSView) -> NSTextView? {
      if let textView = view as? NSTextView { return textView }
      return view.subviews.lazy.compactMap(textView(in:)).first
    }
  }
}
