import Foundation
import Testing

@testable import CodansCore

/// Filesystem contract of `.codans/workflow-runs/`: layout, atomic
/// writes, path containment, the index, and the `.gitignore` upgrade.
/// Every test runs in a fresh temporary worktree root.
struct WorkflowRunStoreTests {
  private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

  private static func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "WorkflowRunStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  private static func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  private static func record(id: UUID = UUID(), status: WorkflowRunStatus = .running, startedAt: Date = stamp)
    -> WorkflowRunRecord
  {
    let definition = WorkflowDefinition(id: "review-loop", name: "Review Loop", steps: [])
    let configuration = WorkflowRunConfiguration(
      id: id,
      definition: definition,
      source: WorkflowRunSource(
        projectID: ProjectID(), worktreeID: WorktreeID(), worktreePath: "/w", worktreeName: "w"),
      bindings: [:],
      runDirectory: "/w/.codans/workflow-runs/\(id.uuidString)",
      cliCommand: "codans",
      startedAt: startedAt
    )
    var run = WorkflowRunState(configuration: configuration)
    run.status = status
    if status.isTerminal { run.finishedAt = startedAt.addingTimeInterval(60) }
    return run.record
  }

  // MARK: - Worktree layout

  @Test
  func ensureWorktreeLayoutWritesTheWorkflowAwareIgnoreFile() throws {
    let root = try Self.makeRoot()
    try WorkflowRunStore.ensureWorktreeLayout(worktreeRoot: root)
    let ignore = root.appending(path: ".codans/.gitignore")
    #expect(try Self.read(ignore) == "*\n!.gitignore\n!workflows/\n")
    #expect(Self.exists(WorkflowRunLayout.runsDirectory(worktreeRoot: root)))
  }

  @Test
  func ensureWorktreeLayoutUpgradesTheLegacyIgnoreFileOnly() throws {
    let root = try Self.makeRoot()
    let ignore = root.appending(path: ".codans/.gitignore")
    try FileManager.default.createDirectory(
      at: root.appending(path: ".codans"), withIntermediateDirectories: true)
    try "*\n".write(to: ignore, atomically: true, encoding: .utf8)
    try WorkflowRunStore.ensureWorktreeLayout(worktreeRoot: root)
    #expect(try Self.read(ignore) == WorkflowRunStore.ignoreFileContents)

    try "*\n!keep-me\n".write(to: ignore, atomically: true, encoding: .utf8)
    try WorkflowRunStore.ensureWorktreeLayout(worktreeRoot: root)
    #expect(try Self.read(ignore) == "*\n!keep-me\n")
  }

  // MARK: - Run layout

  @Test
  func ensureLayoutCreatesTheRunTree() throws {
    let root = try Self.makeRoot()
    let id = UUID()
    let store = WorkflowRunStore(worktreeRoot: root, runID: id)
    try store.ensureLayout()
    #expect(store.runDirectory.path(percentEncoded: false).hasSuffix("/.codans/workflow-runs/\(id.uuidString)/"))
    #expect(Self.exists(store.instructionsDirectory))
    #expect(Self.exists(store.deliveriesDirectory))
    #expect(Self.exists(store.stepsDirectory))
    try store.writeDefinitionCopy(yaml: "name: Review Loop\n")
    #expect(try Self.read(store.definitionURL) == "name: Review Loop\n")
  }

  @Test
  func recordRoundTripsThroughDiskWithSnakeCaseKeys() throws {
    let root = try Self.makeRoot()
    let store = WorkflowRunStore(worktreeRoot: root, runID: UUID())
    #expect(try store.readRecord() == nil)
    let record = Self.record()
    try store.writeRecord(record)
    let json = try Self.read(store.recordURL)
    #expect(json.contains("\"workflow_id\" : \"review-loop\""))
    #expect(json.contains("\"started_at\" : \"2023-11-14T22:13:20Z\""))
    #expect(json.hasPrefix("{\n"))
    #expect(try store.readRecord() == record)
    // No stray temp files after an atomic write.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.runDirectory.path(percentEncoded: false))
      .filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)
  }

  @Test
  func logIsAppendOnlyWithASingleHeading() throws {
    let root = try Self.makeRoot()
    let store = WorkflowRunStore(worktreeRoot: root, runID: UUID())
    try store.appendLog([])
    #expect(!Self.exists(store.logURL))
    try store.appendLog(["[t] start", "[t] step kickoff: launching reviewer"])
    try store.appendLog(["[t] finished: completed"])
    #expect(
      try Self.read(store.logURL)
        == "# Workflow run log\n\n- [t] start\n- [t] step kickoff: launching reviewer\n- [t] finished: completed\n")
  }

  @Test
  func instructionPathMatchesTheLayoutTheMachineRenders() throws {
    let root = try Self.makeRoot()
    let store = WorkflowRunStore(worktreeRoot: root, runID: UUID())
    let url = try store.writeInstruction(stepID: "fix", ordinal: 2, text: "Address the review.")
    #expect(
      url.path(percentEncoded: false)
        == WorkflowRunLayout.instructionPath(
          runDirectory: store.runDirectory.path(percentEncoded: false), stepID: "fix", ordinal: 2))
    #expect(url.lastPathComponent == "fix.2.md")
    #expect(try Self.read(url) == "Address the review.")
  }

  @Test
  func deliveriesKeepEveryVersionAndALatestView() throws {
    let root = try Self.makeRoot()
    let store = WorkflowRunStore(worktreeRoot: root, runID: UUID())
    let first = try store.writeDelivery(name: "review", ordinal: 1, body: "## Findings\n- nit\n")
    #expect(first.path.lastPathComponent == "review.1.md")
    #expect(first.latest.lastPathComponent == "review.md")
    #expect(try Self.read(first.latest) == "## Findings\n- nit\n")
    let second = try store.writeDelivery(name: "review", ordinal: 3, body: "## Findings\nNone.\n")
    #expect(second.latest == first.latest)
    #expect(try Self.read(first.path) == "## Findings\n- nit\n")
    #expect(try Self.read(second.latest) == "## Findings\nNone.\n")
  }

  @Test
  func commandOutputLandsUnderSteps() throws {
    let root = try Self.makeRoot()
    let store = WorkflowRunStore(worktreeRoot: root, runID: UUID())
    let output = try store.writeCommandOutput(stepID: "test", ordinal: 1, stdout: "ok\n", stderr: "")
    #expect(output.stdoutURL.lastPathComponent == "test.1.stdout.log")
    #expect(output.stderrURL.lastPathComponent == "test.1.stderr.log")
    #expect(try Self.read(output.stdoutURL) == "ok\n")
    #expect(try Self.read(output.stderrURL) == "")
  }

  // MARK: - Containment

  @Test
  func pathComponentsAreValidated() throws {
    let root = try Self.makeRoot()
    let store = WorkflowRunStore(worktreeRoot: root, runID: UUID())
    #expect(throws: WorkflowRunStore.Failure.invalidPathComponent("../x")) {
      try store.writeInstruction(stepID: "../x", ordinal: 1, text: "")
    }
    #expect(throws: WorkflowRunStore.Failure.invalidPathComponent("a/b")) {
      try store.writeDelivery(name: "a/b", ordinal: 1, body: "x")
    }
    #expect(throws: WorkflowRunStore.Failure.invalidPathComponent("Review")) {
      try store.writeCommandOutput(stepID: "Review", ordinal: 1, stdout: "", stderr: "")
    }
    #expect(throws: WorkflowRunStore.Failure.invalidPathComponent("0")) {
      try store.writeInstruction(stepID: "fix", ordinal: 0, text: "")
    }
    #expect(!Self.exists(root.appending(path: "x")))
  }

  @Test
  func symlinkedRunDirectoryIsRefused() throws {
    let root = try Self.makeRoot()
    let elsewhere = try Self.makeRoot()
    let id = UUID()
    let runsDirectory = WorkflowRunLayout.runsDirectory(worktreeRoot: root)
    try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
    let link = WorkflowRunLayout.runDirectory(worktreeRoot: root, runID: id)
    try FileManager.default.createSymbolicLink(
      atPath: link.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
      withDestinationPath: elsewhere.path(percentEncoded: false))
    let store = WorkflowRunStore(worktreeRoot: root, runID: id)
    #expect(throws: WorkflowRunStore.Failure.self) {
      try store.ensureLayout()
    }
    #expect(throws: WorkflowRunStore.Failure.self) {
      try store.writeRecord(Self.record(id: id))
    }
    #expect(!Self.exists(elsewhere.appending(path: "run.json")))
  }

  // MARK: - Index

  @Test
  func indexLoadsEmptyWhenMissingAndUpsertsByID() throws {
    let root = try Self.makeRoot()
    var index = try WorkflowRunIndex.load(worktreeRoot: root)
    #expect(index.runs.isEmpty)
    #expect(index.version == 1)
    let running = Self.record()
    index.upsert(WorkflowRunIndex.Entry(running, keep: true))
    var done = running
    done.status = .completed
    index.upsert(WorkflowRunIndex.Entry(done))
    #expect(index.runs.count == 1)
    #expect(index.runs[0].status == "completed")
    // A pin survives a later upsert without it.
    #expect(index.runs[0].keep)
    try WorkflowRunStore.ensureWorktreeLayout(worktreeRoot: root)
    try index.write(worktreeRoot: root)
    let json = try Self.read(WorkflowRunLayout.indexURL(worktreeRoot: root))
    #expect(json.contains("\"workflow_name\" : \"Review Loop\""))
    #expect(try WorkflowRunIndex.load(worktreeRoot: root) == index)
  }

  @Test
  func pruneDropsTheOldestUnpinnedTerminalRuns() throws {
    var index = WorkflowRunIndex()
    var ids: [UUID] = []
    for offset in 0..<25 {
      let record = Self.record(status: .completed, startedAt: Self.stamp.addingTimeInterval(TimeInterval(offset)))
      ids.append(record.id)
      index.upsert(WorkflowRunIndex.Entry(record))
    }
    let live = Self.record(status: .running, startedAt: Self.stamp.addingTimeInterval(-100))
    index.upsert(WorkflowRunIndex.Entry(live))
    let pinned = Self.record(status: .cancelled, startedAt: Self.stamp.addingTimeInterval(-200))
    index.upsert(WorkflowRunIndex.Entry(pinned, keep: true))

    let pruned = index.prune(keepLast: 20)
    #expect(pruned == Array(ids.prefix(5)))
    #expect(index.runs.count == 22)
    #expect(index.runs.contains { $0.id == live.id })
    #expect(index.runs.contains { $0.id == pinned.id })
    #expect(index.prune(keepLast: 20).isEmpty)
  }

  @Test
  func indexingARecordPrunesRunDirectories() throws {
    let root = try Self.makeRoot()
    var old: [URL] = []
    for offset in 0..<3 {
      let record = Self.record(
        status: .failed(step: "x", reason: "y"), startedAt: Self.stamp.addingTimeInterval(TimeInterval(offset)))
      let store = WorkflowRunStore(worktreeRoot: root, runID: record.id)
      try store.writeRecord(record)
      old.append(store.runDirectory)
      try WorkflowRunStore.index(record, worktreeRoot: root, keepLast: 2)
    }
    let newest = Self.record(status: .completed, startedAt: Self.stamp.addingTimeInterval(10))
    try WorkflowRunStore(worktreeRoot: root, runID: newest.id).writeRecord(newest)
    let removed = try WorkflowRunStore.index(newest, worktreeRoot: root, keepLast: 2)
    #expect(removed.map { $0.standardizedFileURL } == [old[0], old[1]].map { $0.standardizedFileURL })
    #expect(!Self.exists(old[0]))
    #expect(!Self.exists(old[1]))
    #expect(Self.exists(old[2]))
    let index = try WorkflowRunIndex.load(worktreeRoot: root)
    #expect(index.runs.map(\.id) == [old[2].lastPathComponent, newest.id.uuidString].compactMap(UUID.init))
  }
}
