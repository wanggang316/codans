import CodansCore
import SwiftUI
import Testing

@testable import Codans

@MainActor
struct TabDragSessionTests {
  let source = PaneID()
  let other = PaneID()

  /// Two Panes side by side: strips 0–30 high, contents below.
  private func session() -> TabDragSession {
    let session = TabDragSession()
    session.setStripFrame(CGRect(x: 0, y: 0, width: 400, height: 30), for: source)
    session.setStripFrame(CGRect(x: 400, y: 0, width: 400, height: 30), for: other)
    session.setContentFrame(CGRect(x: 0, y: 30, width: 400, height: 300), for: source)
    session.setContentFrame(CGRect(x: 400, y: 30, width: 400, height: 300), for: other)
    session.setChipMidXs([500, 600, 700], for: other)
    return session
  }

  private func drag(isLoneTab: Bool = false) -> TabDragSession.Drag {
    TabDragSession.Drag(tabID: TabID(), sourcePaneID: source, isLoneTab: isLoneTab, preview: AnyView(EmptyView()))
  }

  @Test
  func overTheSourceStripIsItsOwnReorder() {
    let session = session()
    session.begin(drag(), at: CGPoint(x: 100, y: 15))
    #expect(session.target == .sourceStrip)
  }

  @Test
  func overAnotherStripInsertsBeforeTheFirstChipRightOfTheCursor() {
    let session = session()
    session.begin(drag(), at: CGPoint(x: 100, y: 15))
    session.move(to: CGPoint(x: 550, y: 15))
    #expect(session.target == .strip(other, index: 1))
    session.move(to: CGPoint(x: 790, y: 15))
    #expect(session.target == .strip(other, index: 3))
    session.move(to: CGPoint(x: 410, y: 15))
    #expect(session.target == .strip(other, index: 0))
  }

  @Test
  func overAContentNamesTheNearestEdge() {
    let session = session()
    session.begin(drag(), at: CGPoint(x: 100, y: 15))
    session.move(to: CGPoint(x: 790, y: 180))
    #expect(session.target == .edge(other, .right))
    session.move(to: CGPoint(x: 600, y: 320))
    #expect(session.target == .edge(other, .bottom))
  }

  @Test
  func aLoneTabCannotSplitOffItsOwnPane() {
    let session = session()
    session.begin(drag(isLoneTab: true), at: CGPoint(x: 100, y: 15))
    session.move(to: CGPoint(x: 10, y: 180))
    #expect(session.target == nil)
    session.move(to: CGPoint(x: 410, y: 180))
    #expect(session.target == .edge(other, .left))
  }

  @Test
  func aTabOfASharedPaneCanSplitOffItsOwnPane() {
    let session = session()
    session.begin(drag(), at: CGPoint(x: 100, y: 15))
    session.move(to: CGPoint(x: 10, y: 180))
    #expect(session.target == .edge(source, .left))
  }

  @Test
  func endCommitsOnlyDropsOnAnotherPane() {
    let session = session()
    var dropped: [(TabID, TabDragSession.Target)] = []
    session.onDrop = { dropped.append(($0, $1)) }
    let tab = drag()
    session.begin(tab, at: CGPoint(x: 100, y: 15))
    #expect(session.end() == .sourceStrip)
    #expect(dropped.isEmpty)

    session.begin(tab, at: CGPoint(x: 100, y: 15))
    session.move(to: CGPoint(x: 550, y: 15))
    #expect(session.end() == .strip(other, index: 1))
    #expect(dropped.count == 1)
    #expect(dropped.first?.0 == tab.tabID)
    #expect(session.drag == nil)
    #expect(session.target == nil)
  }

  @Test
  func outsideEveryFrameIsNoTarget() {
    let session = session()
    session.begin(drag(), at: CGPoint(x: 100, y: 15))
    session.move(to: CGPoint(x: 900, y: 500))
    #expect(session.target == nil)
    #expect(session.end() == nil)
  }

  @Test
  func movesWithoutADragAreIgnored() {
    let session = session()
    session.move(to: CGPoint(x: 550, y: 15))
    #expect(session.target == nil)
  }
}
