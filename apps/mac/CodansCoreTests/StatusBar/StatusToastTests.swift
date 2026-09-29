import Foundation
import Testing

@testable import CodansCore

struct StatusToastTests {
  @Test
  func oneLineKeepsTheFirstNonEmptyLineTrimmed() {
    #expect(StatusToast.oneLine("one") == "one")
    #expect(StatusToast.oneLine("first\nsecond") == "first")
    #expect(StatusToast.oneLine("\n  padded  \n rest") == "padded")
    #expect(StatusToast.oneLine("  \n\n") == "")
  }

  @Test
  func failurePrefixesTheActionAndKeepsOneLine() {
    #expect(
      StatusToast.failure("Merge", reason: "GraphQL: not mergeable\n(details)")
        == .warning("Merge failed: GraphQL: not mergeable"))
    #expect(StatusToast.failure("Prune", reason: " \n") == .warning("Prune failed"))
  }

  @Test
  func displayMessageCapsLongMessagesButKeepsTheFullText() {
    let long = String(repeating: "x", count: 120)
    let toast = StatusToast.warning(long)
    #expect(toast.message == long)
    #expect(toast.displayMessage.count == StatusToast.maxDisplayLength)
    #expect(toast.displayMessage.hasSuffix("…"))
    #expect(StatusToast.success("short").displayMessage == "short")
  }
}

struct StatusActivityTests {
  @Test
  func summaryJoinsTitleAndDetail() {
    let plain = StatusActivity(id: .init("a"), title: "Merging PR #3")
    #expect(plain.summary == "Merging PR #3")
    let detailed = StatusActivity(id: .init("b"), title: "Handing off", detail: "Waiting for Claude")
    #expect(detailed.summary == "Handing off | Waiting for Claude")
  }

  @Test
  func determinateProgressFallsBackToACount() {
    let building = StatusActivity(
      id: .init("build"), title: "Building", progress: .determinate(completed: 118, total: 138))
    #expect(building.summary == "Building | 118/138")
    #expect(building.progress.fraction == 118.0 / 138.0)
    #expect(StatusActivity.Progress.determinate(completed: 5, total: 0).fraction == nil)
    #expect(StatusActivity.Progress.determinate(completed: 9, total: 4).fraction == 1)
    #expect(StatusActivity.Progress.indeterminate.fraction == nil)
  }

  @Test
  func idsCompareByDomainAndKey() {
    #expect(StatusActivityID("pr", 1) == StatusActivityID("pr", "1"))
    #expect(StatusActivityID("pr", 1) != StatusActivityID("pr", 2))
    #expect(StatusActivityID("pr") != StatusActivityID("pr", 1))
    #expect(StatusActivityID("pr", 1).description == "pr:1")
  }
}
