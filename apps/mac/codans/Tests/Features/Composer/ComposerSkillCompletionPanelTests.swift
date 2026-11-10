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
  func panelOpensAboveTheEditorOnItsLeadingEdge() {
    let editor = CGRect(x: 300, y: 400, width: 500, height: 110)
    let frame = Layout.frame(editor: editor, width: 220, height: 200, visible: Self.screen)
    #expect(frame == CGRect(x: 300, y: 510 + Layout.gap, width: 220, height: 200))
  }

  @Test
  func panelOpensBelowTheEditorWhenSpaceAboveIsShort() {
    let editor = CGRect(x: 300, y: 800, width: 500, height: 110)
    let frame = Layout.frame(editor: editor, width: 220, height: 200, visible: Self.screen)
    #expect(frame == CGRect(x: 300, y: 800 - Layout.gap - 200, width: 220, height: 200))
  }

  @Test
  func widthFitsTheWidestNameBetweenTheMinimumAndTheEditor() {
    #expect(Layout.width(names: ["tdd"], maxWidth: 500) == Layout.minWidth)
    let long = String(repeating: "long-skill-name-", count: 4)
    let fitted = Layout.width(names: ["tdd", long], maxWidth: 1000)
    #expect(fitted > Layout.minWidth && fitted < 1000)
    #expect(Layout.width(names: [long, "tdd"], maxWidth: 1000) == fitted)
    #expect(Layout.width(names: [String(repeating: long, count: 4)], maxWidth: 500) == 500)
  }

  @Test
  func widthHasRoomForTheMeasuredNameAndALegacyScroller() {
    let name = "agent-pages:use-agent-pages"
    let text = ceil((name as NSString).size(withAttributes: [.font: Layout.rowFont]).width)
    let rowPadding =
      Layout.iconWidth + Layout.iconSpacing + 2 * Layout.rowHorizontalPadding + 2 * Layout.horizontalPadding
    let overlay = Layout.width(names: [name], maxWidth: 1000, scrollerStyle: .overlay)
    #expect(overlay - rowPadding > text)
    let many = [name] + (0..<Layout.maxVisibleRows).map { "s\($0)" }
    let legacy = Layout.width(names: many, maxWidth: 1000, scrollerStyle: .legacy)
    #expect(legacy == overlay + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    #expect(Layout.width(names: [name], maxWidth: 1000, scrollerStyle: .legacy) == overlay)
  }

  @Test
  func tooltipSitsRightOfThePanelTopAlignedWithTheRow() {
    let panel = CGRect(x: 300, y: 500, width: 200, height: 226)
    let row = CGRect(x: 305, y: 650, width: 190, height: 24)
    let frame = Layout.tooltipFrame(
      row: row, size: CGSize(width: 150, height: 40), panel: panel, visible: Self.screen)
    #expect(frame == CGRect(x: 500 + Layout.tooltipGap, y: 674 - 40, width: 150, height: 40))
  }

  @Test
  func tooltipFlipsLeftWhenTheRightSideHasNoRoom() {
    let panel = CGRect(x: 1300, y: 500, width: 200, height: 226)
    let row = CGRect(x: 1305, y: 650, width: 190, height: 24)
    let frame = Layout.tooltipFrame(
      row: row, size: CGSize(width: 150, height: 40), panel: panel, visible: Self.screen)
    #expect(frame == CGRect(x: 1300 - Layout.tooltipGap - 150, y: 634, width: 150, height: 40))
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
    completion.skills = [
      AgentSkillEntry(
        name: "code-review", summary: "Review a change.", details: Self.reviewDetails, source: .user,
        url: URL(fileURLWithPath: "/tmp/code-review")),
      AgentSkillEntry(name: "tdd", summary: nil, source: .project, url: URL(fileURLWithPath: "/tmp/tdd")),
    ]
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

  private static let reviewDetails =
    "Review a change along two axes, standards and spec, and return both reports with a verdict."

  private var panel: NSWindow? {
    window.childWindows?.first { $0.isVisible && $0 is ComposerSkillCompletionPanel }
  }

  private var tooltip: NSWindow? {
    window.childWindows?.first { $0.isVisible && $0 is ComposerSkillCompletionTooltipPanel }
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
    // Short names: the panel is narrower than the editor.
    let editor = try editorFrameOnScreen(textView)
    #expect(panel.frame.width == Layout.minWidth)
    #expect(panel.frame.minX == editor.minX)
  }

  @Test
  func longNameWidensThePanelUpToTheEditor() throws {
    completion.skills.append(
      AgentSkillEntry(
        name: String(repeating: "very-long-skill-name-", count: 6), summary: nil, source: .plugin,
        url: URL(fileURLWithPath: "/tmp/long")))
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    let panel = try #require(panel)
    #expect(panel.frame.width == (try editorFrameOnScreen(textView)).width)
  }

  @Test
  func tooltipShowsTheHighlightedDescriptionBesideItsRow() throws {
    let visible = try #require(NSScreen.main?.visibleFrame)
    window.setFrameOrigin(CGPoint(x: visible.minX + 100, y: visible.minY + 100))
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    let panel = try #require(panel)
    let tooltip = try #require(tooltip)
    #expect(!tooltip.canBecomeKey)
    #expect(tooltip.ignoresMouseEvents)
    #expect(tooltip.frame.minX >= panel.frame.maxX)
    // The first row's top.
    #expect(tooltip.frame.maxY == panel.frame.maxY - Layout.verticalPadding)
    #expect(tooltip.frame.width <= Layout.tooltipMaxWidth)
    #expect(window.firstResponder === textView)

    // `tdd` has no description.
    _ = completion.handle(.down, text: owner.text)
    settle()
    #expect(self.tooltip == nil)
    _ = completion.handle(.up, text: owner.text)
    settle()
    #expect(self.tooltip != nil)

    type("x ", in: textView)
    #expect(self.tooltip == nil)
  }

  @Test
  func tooltipFlipsLeftAtTheRightEdgeOfTheScreen() throws {
    let visible = try #require(NSScreen.main?.visibleFrame)
    window.setFrameOrigin(CGPoint(x: visible.maxX - 300, y: visible.minY + 100))
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    let panel = try #require(panel)
    let tooltip = try #require(tooltip)
    #expect(tooltip.frame.maxX <= panel.frame.minX)
  }

  private func editorFrameOnScreen(_ textView: NSTextView) throws -> CGRect {
    let scrollView = try #require(textView.enclosingScrollView)
    return window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
  }

  @Test
  func panelOpensAboveTheEditorWhenThereIsRoom() throws {
    let visible = try #require(NSScreen.main?.visibleFrame)
    window.setFrameOrigin(CGPoint(x: visible.minX + 100, y: visible.minY + 100))
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    let panel = try #require(panel)
    let editor = try editorFrameOnScreen(textView)
    #expect(panel.frame.minY >= editor.maxY)
  }

  @Test
  func panelOpensBelowTheEditorAtTheTopOfTheScreen() throws {
    let visible = try #require(NSScreen.main?.visibleFrame)
    window.setFrameTopLeftPoint(CGPoint(x: visible.minX + 100, y: visible.maxY))
    let textView = try show()
    defer { window.close() }
    type("/", in: textView)
    let panel = try #require(panel)
    let editor = try editorFrameOnScreen(textView)
    #expect(panel.frame.maxY <= editor.minY)
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
