import CodansCore
import Foundation
import Testing

@testable import Codans

struct DetachedHandoffTests {
  private let working = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .working, app: "claude-code"))
  private let done = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .done, app: "claude-code"))
  private let note = DetachedPaneSignal.desktopNotification(title: "", body: "ready")

  /// The fence signal as both clients decode it from the daemon's bytes.
  private func fence(_ id: String) -> DetachedPaneSignal {
    var scanner = ZmxOutputScanner()
    return scanner.scan(DetachedHandoff.fenceBytes(id)).first!
  }

  @Test
  func fenceBytesDecodeToAReservedClear() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let id = handoff.nextFence()
    #expect(DetachedHandoff.fenceID(of: fence(id)) == id)
    #expect(DetachedHandoff.fenceID(of: .programStatus(ProgramStatusReport(state: .clear))) == nil)
  }

  /// Stream: [working] f0 [note] f1 [done]. The surface connects between
  /// `note` and f1, so its first fence is f1.
  @Test
  func splitsTheStreamAtTheSurfacesFirstFence() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    let f1 = handoff.nextFence()

    #expect(handoff.watcherRead(working) == .deliver)
    #expect(handoff.watcherRead(fence(f0)) == .drop)
    // After a fence, the split is unknown: hold.
    #expect(handoff.watcherRead(note) == .hold)

    // The surface reads only from f1 on. Its `done` waits: the watcher
    // has not read f1 yet, so it may still hold older signals.
    let first = handoff.surfaceRead(fence(f1))
    #expect(first == .init(admit: false, release: [note], complete: false))
    #expect(!handoff.surfaceRead(done).admit)

    // The watcher reaches f1: it stops, and the surface's `done` follows.
    #expect(handoff.watcherRead(fence(f1)) == .complete([done]))
  }

  /// A newer surface signal never overtakes an older watcher signal.
  @Test
  func surfaceSignalsAfterTheSplitWaitForTheWatcher() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    // Stream: f0 [done]; the surface connected before f0. The watcher is
    // still behind, with `working` (before f0) unread.
    _ = handoff.surfaceRead(fence(f0))
    #expect(!handoff.surfaceRead(done).admit)
    #expect(handoff.watcherRead(working) == .deliver)
    #expect(handoff.watcherRead(fence(f0)) == .complete([done]))
  }

  /// Equal signals on both sides of the split stay distinct: a second
  /// `note` after the fence comes from the surface, not from the watcher.
  @Test
  func equalSignalsOnBothSidesOfTheFenceAreBothDelivered() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    #expect(handoff.watcherRead(note) == .deliver)
    #expect(handoff.watcherRead(fence(f0)) == .drop)
    #expect(handoff.watcherRead(note) == .hold)

    // The surface's first fence is f0: the held `note` is after it.
    let first = handoff.surfaceRead(fence(f0))
    #expect(first == .init(admit: false, release: [], complete: true))
    // The engine ends the handoff on `complete`; afterwards the surface
    // is the source. Within the state machine the split is behind the
    // watcher, so the surface's `note` is admitted at once.
    #expect(handoff.surfaceRead(note).admit)
  }

  @Test
  func surfaceSignalsBeforeItsFirstFenceAreTheWatchers() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    // The surface read `working` before f0; so did the watcher.
    #expect(!handoff.surfaceRead(working).admit)
    #expect(handoff.watcherRead(working) == .deliver)
    #expect(handoff.surfaceRead(fence(f0)).complete == false)
    #expect(handoff.watcherRead(fence(f0)) == .complete([]))
  }

  @Test
  func lateWatcherSignalsAfterTheSplitAreDropped() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    let f1 = handoff.nextFence()
    _ = handoff.surfaceRead(fence(f0))
    #expect(handoff.watcherRead(working) == .deliver)
    #expect(handoff.watcherRead(fence(f0)) == .complete([]))
    // Fences sent before the split was known, read by the surface later.
    #expect(!handoff.surfaceRead(fence(f1)).admit)
  }

  /// The surface never read a fence: the watcher read everything and
  /// stays the source, so nothing is lost.
  @Test
  func abandonWithoutASurfaceFenceKeepsTheWatcher() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    _ = handoff.watcherRead(fence(f0))
    _ = handoff.watcherRead(done)
    #expect(handoff.abandon() == .init(release: [done], surfaceTakesOver: false))
  }

  /// The watcher never reached the split: the surface takes over with
  /// what it read after the split.
  @Test
  func abandonAfterTheSplitHandsOverToTheSurface() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let f0 = handoff.nextFence()
    _ = handoff.surfaceRead(fence(f0))
    _ = handoff.surfaceRead(done)
    #expect(handoff.abandon() == .init(release: [done], surfaceTakesOver: true))
  }

  @Test
  func unknownFencesAreNeverDelivered() {
    var handoff = DetachedHandoff(watcherToken: UUID())
    let stray = fence(DetachedHandoff.fencePrefix + "abc")
    #expect(handoff.watcherRead(stray) == .drop)
    #expect(!handoff.surfaceRead(stray).admit)
  }
}
