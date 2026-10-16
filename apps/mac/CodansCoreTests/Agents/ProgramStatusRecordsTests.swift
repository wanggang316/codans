import Foundation
import Testing

@testable import CodansCore

struct ProgramStatusRecordsTests {
  private func report(
    _ state: ProgramStatusState,
    id: String = "",
    kind: ProgramStatusKind? = nil,
    app: String? = "claude-code",
    message: String? = nil
  ) -> ProgramStatusReport {
    ProgramStatusReport(state: state, kind: kind, id: id, app: app, message: message)
  }

  // MARK: - replacement

  @Test
  func reportReplacesTheWholeRecord() {
    var records = ProgramStatusRecords()
    let changed = records.apply(report(.blocked, kind: .permission, message: "approve Bash"))
    #expect(changed)
    let changed2 = records.apply(report(.working))
    #expect(changed2)
    let root = records.summary?.root
    #expect(root?.state == .working)
    #expect(root?.kind == nil)
    #expect(root?.message == nil)
  }

  @Test
  func identicalReportIsNotAChange() {
    var records = ProgramStatusRecords()
    let changed = records.apply(report(.working))
    #expect(changed)
    let changed2 = records.apply(report(.working))
    #expect(!changed2)
  }

  @Test
  func emptyRecordsHaveNoSummary() {
    #expect(ProgramStatusRecords().summary == nil)
  }

  // MARK: - clear

  @Test
  func clearWithoutIDRemovesEveryRecord() {
    var records = ProgramStatusRecords()
    records.apply(report(.working))
    records.apply(report(.blocked, id: "agent-1", kind: .question))
    let changed = records.apply(report(.clear, app: nil))
    #expect(changed)
    #expect(records.summary == nil)
    #expect(records.isEmpty)
  }

  @Test
  func clearWithIDRemovesTheSubtreeOnly() {
    var records = ProgramStatusRecords()
    records.apply(report(.working))
    records.apply(report(.blocked, id: "build", kind: .question))
    records.apply(report(.blocked, id: "build/test", kind: .permission))
    records.apply(report(.blocked, id: "builder", kind: .auth))
    records.apply(report(.clear, id: "build"))
    #expect(records.count == 2)
    #expect(records.summary?.blockedChild?.kind == .auth)
  }

  @Test
  func clearOfAMissingRecordIsNotAChange() {
    var records = ProgramStatusRecords()
    records.apply(report(.working))
    let changed = records.apply(report(.clear, id: "nope"))
    #expect(!changed)
  }

  // MARK: - children

  @Test
  func childWorkingDoesNotChangeTheActivity() {
    var records = ProgramStatusRecords()
    records.apply(report(.done))
    records.apply(report(.working, id: "agent-1"))
    #expect(records.summary?.activity?.state == .done)
  }

  @Test
  func childBlockedMakesThePaneBlocked() {
    var records = ProgramStatusRecords()
    records.apply(report(.working))
    records.apply(report(.blocked, id: "agent-1", kind: .question, app: nil, message: "Pick one"))
    let activity = records.summary?.activity
    #expect(activity?.state == .blocked)
    #expect(activity?.kind == .question)
    #expect(activity?.message == "Pick one")
  }

  @Test
  func rootBlockedWinsOverChildBlocked() {
    var records = ProgramStatusRecords()
    records.apply(report(.blocked, id: "agent-1", kind: .question))
    records.apply(report(.blocked, kind: .permission, message: "approve"))
    #expect(records.summary?.activity?.kind == .permission)
  }

  @Test
  func childWithoutRootHasNoActivity() {
    var records = ProgramStatusRecords()
    records.apply(report(.blocked, id: "agent-1", kind: .question))
    #expect(records.summary?.root == nil)
    #expect(records.summary?.activity == nil)
  }

  @Test
  func childInheritsAppFromTheNearestAncestor() {
    var records = ProgramStatusRecords()
    records.apply(report(.working, app: "pi"))
    records.apply(report(.blocked, id: "a/b", kind: .question, app: nil))
    #expect(records.summary?.blockedChild?.app == "pi")
  }

  @Test
  func childOfAnotherAppIsIgnored() {
    var records = ProgramStatusRecords()
    records.apply(report(.working, app: "claude-code"))
    records.apply(report(.blocked, id: "deploy", kind: .permission, app: "terraform"))
    #expect(records.summary?.blockedChild == nil)
    #expect(records.summary?.activity?.state == .working)
  }

  // MARK: - lifetime

  @Test
  func dropLiveRecordsKeepsDoneAndError() {
    var records = ProgramStatusRecords()
    records.apply(report(.done))
    records.apply(report(.working, id: "a"))
    records.apply(report(.blocked, id: "b", kind: .permission))
    records.apply(report(.idle, id: "c"))
    records.apply(report(.error, id: "d"))
    let changed = records.dropLiveRecords()
    #expect(changed)
    #expect(records.count == 2)
    let changed2 = records.dropLiveRecords()
    #expect(!changed2)
  }

  @Test
  func evictsTheLeastRecentlyUpdatedRecordWhenFull() {
    var records = ProgramStatusRecords()
    records.apply(report(.working))
    for index in 0..<ProgramStatusRecords.capacity {
      records.apply(report(.working, id: "child-\(index)"))
    }
    #expect(records.count == ProgramStatusRecords.capacity)
    // The root was updated first, so it went first.
    #expect(records.summary?.root == nil)
  }

  // MARK: - governance

  @Test
  func governsOnlyAMatchingAgent() {
    var records = ProgramStatusRecords()
    records.apply(report(.working, app: "claude-code"))
    let summary = records.summary
    #expect(summary?.governs(.claudeCode) == true)
    #expect(summary?.governs(.pi) == false)
    #expect(summary?.governs(.codex) == false)
    #expect(summary?.governs(nil) == false)
  }

  @Test
  func rootWithoutAppGovernsNothing() {
    var records = ProgramStatusRecords()
    records.apply(report(.working, app: nil))
    #expect(records.summary?.governs(.claudeCode) == false)
  }

  // MARK: - text

  @Test
  func textDropsInvisibleFormattingCharacters() {
    let report = ProgramStatusReport(
      state: .blocked, kind: .permission, app: "x",
      title: "\u{202E}evil\u{202C}", message: "a\u{200B}b\u{2066}c\u{FEFF}")
    #expect(report.title == "evil")
    #expect(report.message == "abc")
  }

  @Test
  func emptyTextReadsAsAbsent() {
    let report = ProgramStatusReport(state: .done, app: "", title: "", message: "\u{200B}")
    #expect(report.app == nil)
    #expect(report.title == nil)
    #expect(report.message == nil)
  }
}
