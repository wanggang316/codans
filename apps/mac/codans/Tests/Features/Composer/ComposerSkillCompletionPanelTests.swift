import AppKit
import CodansCore
import Observation
import SwiftUI
import Testing

@testable import Codans

/// The open skill list floats in a child panel of the editor's window, so
/// it never changes the window's layout or size.
@MainActor
@Suite(.serialized)
struct ComposerSkillCompletionPanelTests {
  private typealias Layout = ComposerSkillCompletionPanelLayout

  // MARK: - Placement

  private static let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

  @Test
  func heightShowsAtMostTheVisibleRowsThenScrolls() {
    #expect(Layout.height(rowCount: 1) == Layout.rowHeight + 2 * Layout.verticalPadding)
    #expect(
      Layout.height(rowCount: 50)
        == CGFloat(Layout.maxVisibleRows) * Layout.rowHeight + 2 * Layout.verticalPadding)
  }

  @Test
  func panelOpensAboveTheEditorWithItsWidth() {
    let editor = CGRect(x: 300, y: 400, width: 500, height: 110)
    let frame = Layout.frame(editor: editor, height: 200, visible: Self.screen)
    #expect(frame == CGRect(x: 300, y: 510 + Layout.gap, width: 500, height: 200))
  }

  @Test
  func panelOpensBelowTheEditorWhenSpaceAboveIsShort() {
    let editor = CGRect(x: 300, y: 800, width: 500, height: 110)
    let frame = Layout.frame(editor: editor, height: 200, visible: Self.screen)
    #expect(frame == CGRect(x: 300, y: 800 - Layout.gap - 200, width: 500, height: 200))
  }

  // MARK: - Panel

  @MainActor
  @Observable
  final class Owner {
    var text = ""
  }

  private struct Harness: View {
    @Bindable var owner: Owner
    let selection: ComposerSelection
    let completion: ComposerSkillCompletion

    var body: some View {
      ComposerTextEditor(text: $owner.text, selection: selection)
        .composerSkillCompletion(
          completion, text: owner.text, selection: selection,
          onInsert: { owner.text = $0 }, onSubmit: {}, onCancel: {}
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
      contentRect: NSRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: Harness(owner: owner, selection: selection, completion: completion))
  }

  private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  }

  private func show() throws -> NSTextView {
    window.makeKeyAndOrderFront(nil)
    settle()
    func find(_ view: NSView) -> NSTextView? {
      if let textView = view as? NSTextView { return textView }
      return view.subviews.lazy.compactMap(find).first
    }
    let textView = try #require(window.contentView.flatMap(find))
    window.makeFirstResponder(textView)
    settle()
    return textView
  }

  private func type(_ characters: String, in textView: NSTextView) {
    textView.insertText(characters, replacementRange: textView.selectedRange())
    settle()
  }

  private var panel: NSWindow? {
    window.childWindows?.first { $0.isVisible }
  }

  @Test
  func openListFloatsInAChildPanelAndKeepsTheWindowFrame() throws {
    let textView = try show()
    defer { window.close() }
    let closedFrame = window.frame
    let wasKey = window.isKeyWindow
    #expect(panel == nil)

    type("/", in: textView)
    #expect(completion.isOpen)
    let panel = try #require(panel)
    #expect(window.frame == closedFrame)
    #expect(!panel.canBecomeKey)
    #expect(window.isKeyWindow == wasKey)
    #expect(window.firstResponder === textView)
    #expect(panel.frame.height == Layout.height(rowCount: 2))
  }

  @Test
  func closingTheListHidesThePanel() throws {
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    #expect(panel != nil)
    type("x ", in: textView)
    #expect(!completion.isOpen)
    #expect(panel == nil)
  }

  @Test
  func windowResigningKeyClosesTheList() throws {
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    #expect(panel != nil)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    settle()
    #expect(!completion.isOpen)
    #expect(panel == nil)
  }
}
