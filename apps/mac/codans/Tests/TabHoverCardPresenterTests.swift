import AppKit
import Foundation
import CodansCore
import Testing

@testable import Codans

@MainActor
struct TabHoverCardPresenterTests {
  @Test func showsAfterTheDelayUnderTheChip() async throws {
    let f = Fixture()
    f.presenter.hoverBegan(f.first, title: "Long title", process: { nil })
    #expect(f.presenter.visibleFrame == nil)
    try await Task.sleep(for: .milliseconds(200))
    let card = try #require(f.presenter.visibleFrame)
    let chip = f.screenFrame(of: f.first)
    #expect(abs(card.midX - chip.midX) <= 0.5)
    #expect(card.maxY == chip.minY - TabHoverCardPresenter.verticalGap)
    #expect(card.width <= TabHoverCardView.maxWidth)
  }

  @Test func leavingBeforeTheDelayShowsNothing() async throws {
    let f = Fixture()
    f.presenter.hoverBegan(f.first, title: "Title", process: { nil })
    f.presenter.hoverEnded(f.first)
    try await Task.sleep(for: .milliseconds(200))
    #expect(f.presenter.visibleFrame == nil)
  }

  @Test func movingToAnotherChipSwapsTheCardAtOnce() async throws {
    let f = Fixture()
    f.presenter.hoverBegan(f.first, title: "First", process: { nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(f.presenter.visibleFrame != nil)
    f.presenter.hoverEnded(f.first)
    f.presenter.hoverBegan(f.second, title: "Second", process: { nil })
    let card = try #require(f.presenter.visibleFrame)
    #expect(abs(card.midX - f.screenFrame(of: f.second).midX) <= 0.5)
    #expect(f.presenter.title == "Second")
  }

  @Test func pressHidesTheCardUntilThePointerLeaves() async throws {
    let f = Fixture()
    f.presenter.hoverBegan(f.first, title: "Title", process: { nil })
    try await Task.sleep(for: .milliseconds(200))
    f.presenter.pressed(f.first)
    #expect(f.presenter.visibleFrame == nil)
    f.presenter.hoverBegan(f.first, title: "Title", process: { nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(f.presenter.visibleFrame == nil)
    f.presenter.hoverEnded(f.first)
    f.presenter.hoverBegan(f.first, title: "Title", process: { nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(f.presenter.visibleFrame != nil)
  }

  @Test func inactiveAppShowsNothing() async throws {
    let f = Fixture(isAppActive: false)
    f.presenter.hoverBegan(f.first, title: "Title", process: { nil })
    try await Task.sleep(for: .milliseconds(200))
    #expect(f.presenter.visibleFrame == nil)
  }

  @Test func onlyTheOwningChipRenamesTheCard() {
    let f = Fixture()
    f.presenter.hoverBegan(f.first, title: "Old", process: { nil })
    f.presenter.titleChanged(f.second, to: "Other")
    #expect(f.presenter.title == "Old")
    f.presenter.titleChanged(f.first, to: "New")
    #expect(f.presenter.title == "New")
  }

  @Test func processRowMakesTheCardTaller() async throws {
    let f = Fixture()
    f.presenter.hoverBegan(f.first, title: "Title", process: { nil })
    try await Task.sleep(for: .milliseconds(200))
    let titleOnly = try #require(f.presenter.visibleFrame)
    f.presenter.hoverEnded(f.first)
    f.presenter.hoverBegan(f.first, title: "Title", process: { Self.claude })
    let withProcess = try #require(f.presenter.visibleFrame)
    #expect(withProcess.height > titleOnly.height)
  }

  private static let claude = WorktreeProcessEntry(
    paneID: PaneID(), projectID: ProjectID(), worktreeID: WorktreeID(), tabID: TabID(),
    name: "Claude Code", kind: .agent, pid: 100, startedAt: nil, observedAt: .now,
    workingDirectory: "/repo", processName: "claude", agentKind: .claudeCode)

  /// A window with two chip-sized views side by side, as in a tab bar.
  @MainActor
  private struct Fixture {
    let presenter: TabHoverCardPresenter
    let window: NSWindow
    let first = TabHoverCardAnchor()
    let second = TabHoverCardAnchor()

    init(isAppActive: Bool = true) {
      presenter = TabHoverCardPresenter(showDelay: .milliseconds(50), isAppActive: { isAppActive })
      window = NSWindow(
        contentRect: CGRect(x: 200, y: 300, width: 400, height: 200), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      for (anchor, x) in [(first, 10.0), (second, 140.0)] {
        let view = NSView(frame: CGRect(x: x, y: 150, width: 120, height: 24))
        window.contentView?.addSubview(view)
        anchor.view = view
      }
      window.orderFrontRegardless()
    }

    func screenFrame(of anchor: TabHoverCardAnchor) -> CGRect {
      let view = anchor.view!
      return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
  }
}
