import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct PaneMoveSessionTests {
  private let left = PaneID()
  private let right = PaneID()

  private func session() -> PaneMoveSession {
    let session = PaneMoveSession()
    session.frames = [
      left: CGRect(x: 0, y: 0, width: 100, height: 200),
      right: CGRect(x: 106, y: 0, width: 100, height: 200),
    ]
    return session
  }

  @Test func dragOverAnotherPaneTargetsItsNearestEdge() {
    let session = session()
    session.drag(left, to: CGPoint(x: 156, y: 190))
    #expect(session.source == left)
    #expect(session.target == right)
    #expect(session.zone == .bottom)
  }

  @Test func dragOverTheSourceOrTheGapHasNoTarget() {
    let session = session()
    session.drag(left, to: CGPoint(x: 156, y: 100))
    session.drag(left, to: CGPoint(x: 50, y: 100))
    #expect(session.target == nil)
    #expect(session.zone == nil)
    session.drag(left, to: CGPoint(x: 103, y: 100))
    #expect(session.target == nil)
  }

  @Test func finishReturnsTheDropAndClears() {
    let session = session()
    session.drag(left, to: CGPoint(x: 110, y: 100))
    let drop = session.finish()
    #expect(drop?.source == left)
    #expect(drop?.anchor == right)
    #expect(drop?.zone == .left)
    #expect(session.source == nil)
    #expect(session.target == nil)
  }

  @Test func finishWithoutTargetReturnsNilAndClears() {
    let session = session()
    session.drag(left, to: CGPoint(x: 50, y: 100))
    #expect(session.finish() == nil)
    #expect(session.source == nil)
  }
}
