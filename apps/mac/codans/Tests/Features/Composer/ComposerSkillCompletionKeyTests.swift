import AppKit
import CodansCore
import Observation
import SwiftUI
import Testing

@testable import Codans

/// Key routing through a real `TextEditor` with the modifier `NewAgentView`
/// uses: the open list takes Return, Tab, the arrows, and Escape; the
/// closed list hands Return and Escape to the owner. Key events go through the window, so they
/// reach SwiftUI the way typed keys do.
@MainActor
@Suite(.serialized)
struct ComposerSkillCompletionKeyTests {
  @MainActor
  @Observable
  final class Owner {
    var text = ""
    var sent = 0
    var closed = 0
  }

  private struct Harness: View {
    @Bindable var owner: Owner
    let selection: ComposerSelection
    let completion: ComposerSkillCompletion

    var body: some View {
      ComposerTextEditor(text: $owner.text, selection: selection, placeholder: "")
        .composerSkillCompletion(
          completion, text: owner.text, selection: selection,
          onInsert: { owner.text = $0 },
          onSubmit: { owner.sent += 1 },
          onCancel: { owner.closed += 1 }
        )
        .frame(width: 300, height: 120)
    }
  }

  private let owner = Owner()
  private let selection = ComposerSelection()
  private let completion = ComposerSkillCompletion()
  private let window: NSWindow

  init() {
    completion.location = .claudeCode
    completion.skills = ["code-review", "tdd"].map {
      AgentSkillEntry(name: $0, summary: nil, source: .user, url: URL(fileURLWithPath: "/tmp/\($0)"))
    }
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Harness(owner: owner, selection: selection, completion: completion))
  }

  private func textView() -> NSTextView? {
    func find(_ view: NSView) -> NSTextView? {
      if let textView = view as? NSTextView { return textView }
      return view.subviews.lazy.compactMap(find).first
    }
    return window.contentView.flatMap(find)
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }

  private func show() throws -> NSTextView {
    window.makeKeyAndOrderFront(nil)
    settle()
    let textView = try #require(textView())
    window.makeFirstResponder(textView)
    settle()
    return textView
  }

  private func type(_ characters: String, in textView: NSTextView) {
    textView.insertText(characters, replacementRange: textView.selectedRange())
    settle()
  }

  private func press(
    _ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []
  ) {
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    if let event { window.sendEvent(event) }
    settle()
  }

  private static let returnKey: (UInt16, String) = (36, "\r")
  private static let tabKey: (UInt16, String) = (48, "\t")
  private static let escapeKey: (UInt16, String) = (53, "\u{1b}")
  private static let downKey: (UInt16, String) = (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))

  @Test
  func openListTakesReturnAndEscapeBeforeTheOwner() throws {
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    #expect(completion.isOpen)

    press(Self.downKey.0, Self.downKey.1)
    #expect(completion.highlighted?.name == "tdd")
    press(Self.escapeKey.0, Self.escapeKey.1)
    #expect(!completion.isOpen)
    #expect(owner.closed == 0)

    type(" /co", in: textView)
    #expect(completion.isOpen)
    press(Self.returnKey.0, Self.returnKey.1)
    #expect(owner.text == "/ /code-review ")
    #expect(owner.sent == 0)
    #expect(!completion.isOpen)
  }

  @Test
  func tabInsertsTheHighlightedSkill() throws {
    let textView = try show()
    defer { window.close() }
    type("run /td", in: textView)
    press(Self.tabKey.0, Self.tabKey.1)
    #expect(owner.text == "run /tdd ")
    #expect(owner.sent == 0)
  }

  @Test
  func closedListLetsTheOwnerSendAndClose() throws {
    let textView = try show()
    defer { window.close() }
    type("fix it", in: textView)
    #expect(!completion.isOpen)
    press(Self.returnKey.0, Self.returnKey.1)
    #expect(owner.sent == 1)
    press(Self.escapeKey.0, Self.escapeKey.1)
    #expect(owner.closed == 1)
  }

  @Test
  func caretMovedOutOfTheCallClosesTheList() throws {
    let textView = try show()
    defer { window.close() }
    type("fix /td", in: textView)
    #expect(completion.isOpen)
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    settle()
    #expect(!completion.isOpen)
    // Return now belongs to the owner, and the old call is left alone.
    press(Self.returnKey.0, Self.returnKey.1)
    #expect(owner.sent == 1)
    #expect(owner.text == "fix /td")
  }

  @Test
  func shiftReturnBreaksALineInsteadOfSending() throws {
    let textView = try show()
    defer { window.close() }
    type("fix", in: textView)
    press(Self.returnKey.0, Self.returnKey.1, modifiers: .shift)
    #expect(owner.sent == 0)
    #expect(owner.text == "fix\n")
  }

  /// While an input method composes, Return and Escape confirm or cancel
  /// its text: neither the list nor the owner takes them.
  @Test
  func composingTextKeepsReturnAndEscapeForTheInputMethod() throws {
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    #expect(completion.isOpen)
    func compose() {
      textView.setMarkedText(
        "c", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      settle()
    }
    compose()
    #expect(selection.hasMarkedText)
    // Return confirms the composition, so compose again for Escape.
    press(Self.returnKey.0, Self.returnKey.1)
    #expect(owner.sent == 0)
    #expect(!owner.text.contains("code-review"))
    compose()
    press(Self.escapeKey.0, Self.escapeKey.1)
    #expect(owner.closed == 0)
  }
}
