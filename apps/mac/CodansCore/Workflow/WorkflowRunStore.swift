import Foundation

/// Filesystem store for one run directory (`WorkflowRunLayout`). Pure
/// file work — no subprocesses, no panes — so it is `nonisolated` and
/// `Sendable`. Every path is assembled from validated components, and a
/// run directory that turns out to be a symlink is refused rather than
/// followed, so a hostile worktree cannot redirect the run's writes.
public nonisolated struct WorkflowRunStore: Sendable {
  public enum Failure: Error, Equatable {
    case invalidPathComponent(String)
    case symlinkRefused(path: String)
  }

  /// `steps/*.stdout.log` cap.
  public static let maximumStdoutBytes = 16 * 1024 * 1024
  /// `steps/*.stderr.log` cap.
  public static let maximumStderrBytes = 4 * 1024 * 1024

  public let runDirectory: URL

  public init(runDirectory: URL) {
    self.runDirectory = runDirectory.standardizedFileURL
  }

  public init(worktreeRoot: URL, runID: UUID) {
    self.init(runDirectory: WorkflowRunLayout.runDirectory(worktreeRoot: worktreeRoot, runID: runID))
  }

  // MARK: - Paths

  public var recordURL: URL { WorkflowRunLayout.recordURL(runDirectory: runDirectory) }
  public var logURL: URL { WorkflowRunLayout.logURL(runDirectory: runDirectory) }
  public var definitionURL: URL { WorkflowRunLayout.definitionURL(runDirectory: runDirectory) }
  public var instructionsDirectory: URL { WorkflowRunLayout.instructionsDirectory(runDirectory: runDirectory) }
  public var deliveriesDirectory: URL { WorkflowRunLayout.deliveriesDirectory(runDirectory: runDirectory) }
  public var stepsDirectory: URL { WorkflowRunLayout.stepsDirectory(runDirectory: runDirectory) }

  // MARK: - Worktree layout

  /// The `.gitignore` `.codans/` carries once workflows exist: the state
  /// directory still ignores itself, but repository-scoped definitions
  /// under `workflows/` can be committed.
  public static let ignoreFileContents = "*\n!.gitignore\n!workflows/\n"

  /// Creates `.codans/workflow-runs/` and upgrades `.codans/.gitignore`
  /// when it is missing or still the pre-workflow `*`. Any other content
  /// is the user's and is left alone.
  public static func ensureWorktreeLayout(worktreeRoot: URL) throws {
    let fileManager = FileManager.default
    let stateDirectory = worktreeRoot.appending(path: WorkflowRunLayout.stateDirectoryName, directoryHint: .isDirectory)
    try fileManager.createDirectory(
      at: WorkflowRunLayout.runsDirectory(worktreeRoot: worktreeRoot), withIntermediateDirectories: true)
    let ignoreURL = stateDirectory.appending(path: HandoffLayout.ignoreFileName)
    let existing = try? String(contentsOf: ignoreURL, encoding: .utf8)
    let stillLegacy = existing?.trimmingCharacters(in: .whitespacesAndNewlines) == "*"
    if existing == nil || stillLegacy {
      try ignoreFileContents.write(to: ignoreURL, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - Run layout

  public func ensureLayout() throws {
    try refuseSymlink(runDirectory)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: instructionsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: deliveriesDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: stepsDirectory, withIntermediateDirectories: true)
    try refuseSymlink(instructionsDirectory)
    try refuseSymlink(deliveriesDirectory)
    try refuseSymlink(stepsDirectory)
  }

  /// The definition as it was when the run started; the run only ever
  /// reads this copy.
  public func writeDefinitionCopy(yaml: String) throws {
    try ensureLayout()
    try writeAtomically(yaml, to: definitionURL)
  }

  // MARK: - Record

  public func writeRecord(_ record: WorkflowRunRecord) throws {
    try ensureLayout()
    try refuseSymlink(recordURL)
    try AtomicFileStore.write(record, to: recordURL, encoder: WorkflowRunRecord.encoder)
  }

  public func readRecord() throws -> WorkflowRunRecord? {
    try AtomicFileStore.read(WorkflowRunRecord.self, at: recordURL, decoder: WorkflowRunRecord.decoder)
  }

  // MARK: - Log

  /// Appends lines to `log.md`, creating it with a heading on first use.
  public func appendLog(_ lines: [String]) throws {
    guard !lines.isEmpty else { return }
    try ensureLayout()
    try refuseSymlink(logURL)
    Self.logLock.lock()
    defer { Self.logLock.unlock() }
    if !FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)) {
      try "# Workflow run log\n\n".write(to: logURL, atomically: true, encoding: .utf8)
    }
    let handle = try FileHandle(forWritingTo: logURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((lines.map { "- \($0)\n" }.joined()).utf8))
  }

  private static let logLock = NSLock()

  // MARK: - Instructions

  @discardableResult
  public func writeInstruction(stepID: String, ordinal: Int, text: String) throws -> URL {
    try Self.validate(identifier: stepID)
    try Self.validate(ordinal: ordinal)
    try ensureLayout()
    let url = WorkflowRunLayout.instructionURL(runDirectory: runDirectory, stepID: stepID, ordinal: ordinal)
    try writeAtomically(text, to: url)
    return url
  }

  // MARK: - Deliveries

  /// Writes `<name>.<ordinal>.md`, then atomically replaces `<name>.md`
  /// so the latest view is never half-written.
  public func writeDelivery(name: String, ordinal: Int, body: String) throws -> (path: URL, latest: URL) {
    try Self.validate(identifier: name)
    try Self.validate(ordinal: ordinal)
    try ensureLayout()
    let versioned = WorkflowRunLayout.deliveryURL(runDirectory: runDirectory, name: name, ordinal: ordinal)
    let latest = WorkflowRunLayout.latestDeliveryURL(runDirectory: runDirectory, name: name)
    try writeAtomically(body, to: versioned)
    try writeAtomically(body, to: latest)
    return (versioned, latest)
  }

  // MARK: - Command output

  /// Persists a `run:` step's output, truncated to the layout's caps.
  public func writeCommandOutput(
    stepID: String, ordinal: Int, stdout: String, stderr: String
  ) throws -> (stdoutURL: URL, stderrURL: URL) {
    try Self.validate(identifier: stepID)
    try Self.validate(ordinal: ordinal)
    try ensureLayout()
    let stdoutURL = WorkflowRunLayout.stdoutURL(runDirectory: runDirectory, stepID: stepID, ordinal: ordinal)
    let stderrURL = WorkflowRunLayout.stderrURL(runDirectory: runDirectory, stepID: stepID, ordinal: ordinal)
    try writeAtomically(WorkflowMachine.truncated(stdout, toBytes: Self.maximumStdoutBytes), to: stdoutURL)
    try writeAtomically(WorkflowMachine.truncated(stderr, toBytes: Self.maximumStderrBytes), to: stderrURL)
    return (stdoutURL, stderrURL)
  }

  // MARK: - Containment

  static func validate(identifier: String) throws {
    guard WorkflowDefinition.isValidIdentifier(identifier) else {
      throw Failure.invalidPathComponent(identifier)
    }
  }

  static func validate(ordinal: Int) throws {
    guard ordinal > 0 else { throw Failure.invalidPathComponent(String(ordinal)) }
  }

  /// `lstat` rather than `attributesOfItem`: a directory URL carries a
  /// trailing slash, and with it the Foundation call follows the link
  /// and reports the target instead of the link itself.
  private func refuseSymlink(_ url: URL) throws {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    var status = stat()
    guard lstat(path, &status) == 0 else { return }
    if (status.st_mode & S_IFMT) == S_IFLNK {
      throw Failure.symlinkRefused(path: path)
    }
  }

  /// Temp file next to the target, then rename — the same story as
  /// `AtomicFileStore`, for text.
  private func writeAtomically(_ text: String, to url: URL) throws {
    try refuseSymlink(url)
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    do {
      try text.write(to: temporary, atomically: false, encoding: .utf8)
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}

// MARK: - Index

/// `<worktree>/.codans/workflow-runs/index.json`: one line per run, so
/// `codans workflow runs` and pruning never open every `run.json`.
public nonisolated struct WorkflowRunIndex: Equatable, Sendable, Codable {
  public static let currentVersion = 1
  public static let defaultRetainedRuns = 20

  public struct Entry: Equatable, Sendable, Codable {
    public var id: UUID
    public var workflowID: String
    public var workflowName: String
    /// `WorkflowRunStatus.stateName`.
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?
    /// Pinned by the user; never pruned.
    public var keep: Bool

    public init(
      id: UUID,
      workflowID: String,
      workflowName: String,
      status: String,
      startedAt: Date,
      finishedAt: Date? = nil,
      keep: Bool = false
    ) {
      self.id = id
      self.workflowID = workflowID
      self.workflowName = workflowName
      self.status = status
      self.startedAt = startedAt
      self.finishedAt = finishedAt
      self.keep = keep
    }

    public init(_ record: WorkflowRunRecord, keep: Bool = false) {
      self.init(
        id: record.id,
        workflowID: record.workflowID,
        workflowName: record.workflowName,
        status: record.status.stateName,
        startedAt: record.startedAt,
        finishedAt: record.finishedAt,
        keep: keep
      )
    }

    public var isTerminal: Bool {
      status != "running" && status != "needs_attention"
    }

    enum CodingKeys: String, CodingKey {
      case id
      case workflowID = "workflow_id"
      case workflowName = "workflow_name"
      case status
      case startedAt = "started_at"
      case finishedAt = "finished_at"
      case keep
    }
  }

  public var version: Int
  public var runs: [Entry]

  public init(runs: [Entry] = []) {
    version = Self.currentVersion
    self.runs = runs
  }

  /// A missing file is an empty index.
  public static func load(from url: URL) throws -> WorkflowRunIndex {
    try AtomicFileStore.read(WorkflowRunIndex.self, at: url, decoder: WorkflowRunRecord.decoder) ?? WorkflowRunIndex()
  }

  public static func load(worktreeRoot: URL) throws -> WorkflowRunIndex {
    try load(from: WorkflowRunLayout.indexURL(worktreeRoot: worktreeRoot))
  }

  public func write(to url: URL) throws {
    try AtomicFileStore.write(self, to: url, encoder: WorkflowRunRecord.encoder)
  }

  public func write(worktreeRoot: URL) throws {
    try write(to: WorkflowRunLayout.indexURL(worktreeRoot: worktreeRoot))
  }

  public mutating func upsert(_ entry: Entry) {
    if let index = runs.firstIndex(where: { $0.id == entry.id }) {
      var merged = entry
      merged.keep = runs[index].keep || entry.keep
      runs[index] = merged
    } else {
      runs.append(entry)
    }
  }

  /// Drops the oldest terminal, unpinned runs beyond `keepLast` and
  /// returns their ids — the directories the caller deletes.
  @discardableResult
  public mutating func prune(keepLast: Int = WorkflowRunIndex.defaultRetainedRuns) -> [UUID] {
    let candidates = runs.filter { $0.isTerminal && !$0.keep }.sorted { $0.startedAt < $1.startedAt }
    let excess = max(0, candidates.count - keepLast)
    let doomed = Set(candidates.prefix(excess).map(\.id))
    runs.removeAll { doomed.contains($0.id) }
    return candidates.prefix(excess).map(\.id)
  }
}

extension WorkflowRunStore {
  /// Records the run in the worktree index and prunes old runs, deleting
  /// their directories. Returns the directories removed.
  @discardableResult
  public static func index(
    _ record: WorkflowRunRecord, worktreeRoot: URL, keepLast: Int = WorkflowRunIndex.defaultRetainedRuns
  ) throws -> [URL] {
    try ensureWorktreeLayout(worktreeRoot: worktreeRoot)
    var index = try WorkflowRunIndex.load(worktreeRoot: worktreeRoot)
    index.upsert(WorkflowRunIndex.Entry(record))
    let pruned = index.prune(keepLast: keepLast)
    try index.write(worktreeRoot: worktreeRoot)
    var removed: [URL] = []
    for id in pruned {
      let directory = WorkflowRunLayout.runDirectory(worktreeRoot: worktreeRoot, runID: id)
      if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
        try FileManager.default.removeItem(at: directory)
        removed.append(directory)
      }
    }
    return removed
  }
}
