import CodansCore
import Testing

@testable import Codans

struct DetachedHandoffLedgerTests {
  private let working = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .working, app: "claude-code"))
  private let done = DetachedPaneSignal.programStatus(
    ProgramStatusReport(state: .done, app: "claude-code"))
  private let note = DetachedPaneSignal.desktopNotification(title: "", body: "ready")

  /// Feed `steps` to a fresh ledger; returns which ones were admitted.
  private func admitted(
    _ steps: [(DetachedPaneSignal, DetachedHandoffLedger.Source)]
  ) -> [Bool] {
    var ledger = DetachedHandoffLedger()
    return steps.map { ledger.admit($0.0, from: $0.1) }
  }

  @Test
  func deliversEachOverlappedSignalOnce() {
    let result = admitted([
      // Before the surface connects, only the watcher sees output.
      (working, .watcher),
      // Overlap: the surface reports first, then the watcher's copy.
      (note, .surface), (note, .watcher),
      // Overlap: the watcher reports first, then the surface's copy.
      (done, .watcher), (done, .surface),
    ])
    #expect(result == [true, true, false, true, false])
  }

  @Test
  func lateWatcherCopyDoesNotRegressTheState() {
    let result = admitted([
      (working, .surface), (done, .surface),
      // The watcher's copies arrive after the surface moved on.
      (working, .watcher), (done, .watcher),
    ])
    #expect(result == [true, true, false, false])
  }

  @Test
  func repeatedSignalsPairByOccurrence() {
    let result = admitted([
      (working, .watcher), (working, .watcher),
      (working, .surface), (working, .surface), (working, .surface),
    ])
    #expect(result == [true, true, false, false, true])
  }

  @Test
  func signalsOutsideTheOverlapNeverMatchLaterCopies() {
    let result = admitted([
      // Seen by the watcher only, before the surface connected.
      (working, .watcher), (done, .watcher),
      (done, .surface),
      // A new `working` after the overlap is new output, not the old one.
      (working, .surface),
    ])
    #expect(result == [true, true, false, true])
  }
}
