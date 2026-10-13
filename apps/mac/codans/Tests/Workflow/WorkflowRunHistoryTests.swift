import CodansCore
import Foundation
import Testing

@testable import Codans

struct WorkflowRunHistoryTests {
  @Test
  func logLinesSplitIntoTimeAndTextAndDropTheHeading() {
    let lines = WorkflowRunLogView.parse(
      """
      # Workflow run log

      - [2026-09-23T13:04:25Z] start: Advisor (advisor)
      - [2026-09-23T13:06:09Z] step ask: success
      a line without a stamp
      """)
    #expect(lines.map(\.text) == ["start: Advisor (advisor)", "step ask: success", "a line without a stamp"])
    #expect(lines[0].time == ISO8601DateFormatter().date(from: "2026-09-23T13:04:25Z"))
    #expect(lines[2].time == nil)
  }

  @Test
  func historyReadsEachWorktreesIndexNewestFirst() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "run-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: WorkflowRunLayout.runsDirectory(worktreeRoot: root), withIntermediateDirectories: true)
    let older = UUID()
    let newer = UUID()
    let index = WorkflowRunIndex(runs: [
      .init(
        id: older, workflowID: "advisor", workflowName: "Advisor", status: "completed",
        startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 200)),
      .init(
        id: newer, workflowID: "review-loop", workflowName: "Review Loop", status: "needs_attention",
        startedAt: Date(timeIntervalSince1970: 300), finishedAt: nil),
    ])
    try index.write(worktreeRoot: root)

    let summaries = WorkflowRunHistory.load(worktrees: [(name: "wt", path: root.path(percentEncoded: false))])
    #expect(summaries.map(\.id) == [newer, older])
    #expect(summaries[0].needsAttention)
    #expect(!summaries[0].isTerminal)
    #expect(summaries[1].worktreeName == "wt")
    #expect(summaries[1].runDirectory == WorkflowRunLayout.runDirectory(worktreeRoot: root, runID: older))
  }

  @Test
  func deliveriesListOrdinalFilesOnly() throws {
    let runDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "run-deliveries-\(UUID().uuidString)", isDirectory: true)
    let deliveries = WorkflowRunLayout.deliveriesDirectory(runDirectory: runDirectory)
    try FileManager.default.createDirectory(at: deliveries, withIntermediateDirectories: true)
    for name in ["review.md", "review.1.md", "review.2.md", "fixes.1.md"] {
      try Data("x".utf8).write(to: deliveries.appendingPathComponent(name))
    }
    #expect(
      WorkflowRunHistory.deliveries(runDirectory: runDirectory).map(\.lastPathComponent)
        == ["fixes.1.md", "review.1.md", "review.2.md"])
  }
}
