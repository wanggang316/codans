import Foundation

/// On-disk store for the cross-agent handoff artifact under a worktree's
/// `.codans/handoff/` directory.
///
/// Layout:
/// ```
/// <worktree>/.codans/handoff/
///   .gitignore            "*" — the whole directory ignores itself
///   current.md            agent-authored briefing (absent when none)
///   context.md            codans-generated repository and session state
///   log.md                append-only handoff history
///   archive/<ts>-<from>-to-<to>.md      outgoing snapshot of each transition
///   archive/<ts>-replaced-current.md    briefing replaced by a checkpoint
///   sessions/<ts>-<pane>.md             screen excerpt per save
/// ```
///
/// Agent-authored prose lives only in `current.md`; codans writes generated
/// state to `context.md`, so a background save never rewrites what the agent
/// wrote. Pure filesystem work — no subprocesses — so the type is
/// `nonisolated` and `Sendable` and runs off the main actor.
public nonisolated struct HandoffStore: Sendable {
  public static let stateDirectoryName = ".codans"
  public static let handoffDirectoryName = "handoff"

  /// The worktree root the artifact lives under.
  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  // MARK: - Paths

  public var stateDirectory: URL {
    rootURL.appending(path: Self.stateDirectoryName, directoryHint: .isDirectory)
  }
  public var handoffDirectory: URL {
    stateDirectory.appending(path: Self.handoffDirectoryName, directoryHint: .isDirectory)
  }
  public var currentURL: URL { handoffDirectory.appending(path: "current.md") }
  public var contextURL: URL { handoffDirectory.appending(path: "context.md") }
  public var logURL: URL { handoffDirectory.appending(path: "log.md") }
  public var ignoreURL: URL { handoffDirectory.appending(path: ".gitignore") }
  public var archiveDirectory: URL {
    handoffDirectory.appending(path: "archive", directoryHint: .isDirectory)
  }
  public var sessionsDirectory: URL {
    handoffDirectory.appending(path: "sessions", directoryHint: .isDirectory)
  }

  public var hasCurrentBriefing: Bool {
    FileManager.default.fileExists(atPath: currentURL.path(percentEncoded: false))
  }

  /// Path of `url` relative to the `.codans/` directory — the form the
  /// receiver's kickoff prompt and the CLI payload quote.
  public func relativePath(of url: URL) -> String {
    let base = stateDirectory.path(percentEncoded: false)
    let full = url.path(percentEncoded: false)
    guard full.hasPrefix(base) else { return full }
    return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  // MARK: - Layout

  /// Creates the directory tree and its self-ignoring `.gitignore`. Never
  /// seeds `current.md`: the briefing exists only as the product of a
  /// validated agent document.
  public func ensureLayout() throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: ignoreURL.path(percentEncoded: false)) {
      try "*\n".write(to: ignoreURL, atomically: true, encoding: .utf8)
    }
  }

  // MARK: - Briefing

  /// Installs a validated briefing as `current.md`. With `archivingPrevious`
  /// the existing file is snapshotted into `archive/` first so a rewrite
  /// can never destroy the only copy of the previous round. Transitions pass
  /// `false` because they already archived the outgoing state as a combined
  /// snapshot.
  public func writeBriefing(_ artifact: String, archivingPrevious: Bool, now: Date) throws {
    try ensureLayout()
    if archivingPrevious {
      try snapshotCurrentBeforeRewrite(now: now)
    }
    try artifact.write(to: currentURL, atomically: true, encoding: .utf8)
  }

  /// Removes `current.md` after the caller archived it. Without a fresh
  /// briefing the receiver must read `context.md` and the archive chain — a
  /// previous round's briefing must never pose as the current contract.
  public func removeCurrentBriefing() throws {
    guard hasCurrentBriefing else { return }
    try FileManager.default.removeItem(at: currentURL)
  }

  private func snapshotCurrentBeforeRewrite(now: Date) throws {
    guard hasCurrentBriefing else { return }
    let existing = try String(contentsOf: currentURL, encoding: .utf8)
    let stem = "\(Self.fileStamp(now))-replaced-current"
    let destination = try Self.reserveFile(in: archiveDirectory, stem: stem)
    try Self.writeOrDiscard(existing, to: destination)
  }

  // MARK: - Archive

  /// Copies the current briefing plus generated context into
  /// `archive/<ts>-<from>-to-<to>.md`, leaving `current.md` in place for the
  /// caller to replace or remove. Returns the archived path relative to
  /// `.codans/`, or `nil` when there was nothing to archive.
  @discardableResult
  public func archiveCurrent(from: String, to: String, now: Date) throws -> String? {
    guard hasCurrentBriefing else { return nil }
    try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
    let stem = "\(Self.fileStamp(now))-\(Self.slug(from))-to-\(Self.slug(to))"
    let destination = try Self.reserveFile(in: archiveDirectory, stem: stem)
    let prose = try String(contentsOf: currentURL, encoding: .utf8)
    let context = (try? String(contentsOf: contextURL, encoding: .utf8)) ?? ""
    let snapshot =
      context.isEmpty
      ? prose
      : "\(prose.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(context)\n"
    try Self.writeOrDiscard(snapshot, to: destination)
    return relativePath(of: destination)
  }

  // MARK: - Context

  /// Rewrites `context.md` from the given repository and session facts.
  public func writeContext(
    outgoingAgent: AgentKind?,
    repo: HandoffRepoState,
    session: HandoffSessionRecord?,
    now: Date
  ) throws {
    try ensureLayout()
    let rendered = Self.renderContext(
      rootName: rootURL.lastPathComponent,
      outgoingAgent: outgoingAgent,
      repo: repo,
      session: session,
      now: now
    )
    try rendered.write(to: contextURL, atomically: true, encoding: .utf8)
  }

  static func renderContext(
    rootName: String,
    outgoingAgent: AgentKind?,
    repo: HandoffRepoState,
    session: HandoffSessionRecord?,
    now: Date
  ) -> String {
    var lines: [String] = []
    lines.append("# Handoff Context")
    lines.append("")
    lines.append("Generated by codans at \(iso(now)). Regenerated on every save; do not edit.")
    lines.append("")
    lines.append("## Outgoing Agent")
    lines.append("")
    lines.append("- Agent: \(outgoingAgent?.displayName ?? "unknown")")
    lines.append("")
    lines.append("## Repository")
    lines.append("")
    lines.append("- Root: \(rootName)")
    if repo.isGit {
      lines.append("- Branch: \(repo.branch ?? "(detached)")")
      lines.append("- Changed files: \(repo.changedFiles.count)")
      lines.append("- Uncommitted diff: +\(repo.additions) / -\(repo.deletions)")
      if !repo.changedFiles.isEmpty {
        lines.append("")
        lines.append("### Changed Files")
        lines.append("")
        lines.append(contentsOf: repo.changedFiles.map { "- `\($0)`" })
      }
    } else {
      lines.append("- Not a git repository")
    }
    if let session {
      lines.append("")
      lines.append("## Session Context")
      lines.append("")
      lines.append("- Agent: \(session.agent ?? "unknown")")
      lines.append("- Session ID: \(session.sessionID ?? "unknown")")
      lines.append("- Pane: \(session.paneID)\(session.paneTitle.map { " (\($0))" } ?? "")")
      lines.append("- Screen excerpt: `\(session.excerptPath)`")
      if let resume = session.resumeCommand {
        lines.append("- Reattach to the outgoing session: `\(resume)`")
      }
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  // MARK: - Sessions

  /// Persists the outgoing pane's screen excerpt under `sessions/` and
  /// returns the record `context.md` and the CLI payload describe it by.
  public func writeSession(_ context: HandoffSessionContext, now: Date) throws -> HandoffSessionRecord {
    try ensureLayout()
    let stem = "\(Self.fileStamp(now))-\(Self.slug(context.paneID))"
    let destination = try Self.reserveFile(in: sessionsDirectory, stem: stem)
    let record = HandoffSessionRecord(
      agent: context.agentKind?.rawValue,
      sessionID: context.sessionID,
      paneID: context.paneID,
      paneTitle: context.paneTitle,
      excerptPath: relativePath(of: destination),
      resumeCommand: context.resumeCommand
    )
    try Self.writeOrDiscard(Self.renderSession(context, now: now), to: destination)
    return record
  }

  static func renderSession(_ context: HandoffSessionContext, now: Date) -> String {
    var lines: [String] = []
    lines.append("# Handoff Session Excerpt")
    lines.append("")
    lines.append("- Captured: \(iso(now))")
    lines.append("- Agent: \(context.agentKind?.displayName ?? "unknown")")
    lines.append("- Session ID: \(context.sessionID ?? "unknown")")
    lines.append("- Pane: \(context.paneID)\(context.paneTitle.map { " (\($0))" } ?? "")")
    if let resume = context.resumeCommand {
      lines.append("- Reattach: `\(resume)`")
    }
    lines.append("")
    lines.append("## Last Screen")
    lines.append("")
    let excerpt = context.screenExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if excerpt.isEmpty {
      lines.append("_No screen text was captured._")
    } else {
      lines.append("```text")
      lines.append(excerpt)
      lines.append("```")
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  // MARK: - Log

  /// Appends one timestamped line to `log.md`, creating the file on first
  /// use. Serialised process-wide because two entry points (CLI handler and
  /// HUD fallback) may log the same worktree concurrently.
  public func appendLog(_ event: String, now: Date) throws {
    try FileManager.default.createDirectory(at: handoffDirectory, withIntermediateDirectories: true)
    let line = "- \(Self.iso(now))  \(event)\n"
    Self.logLock.lock()
    defer { Self.logLock.unlock() }
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: logURL.path(percentEncoded: false)) {
      try "# Handoff log\n\n".write(to: logURL, atomically: true, encoding: .utf8)
    }
    let handle = try FileHandle(forWritingTo: logURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(line.utf8))
  }

  private static let logLock = NSLock()

  // MARK: - Naming helpers

  /// `yyyyMMdd-HHmmss` in UTC — sorts lexically in archive listings.
  static func fileStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }

  static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  /// Lowercased `[a-z0-9-]` form for filenames; empty input becomes "agent".
  static func slug(_ raw: String) -> String {
    let lowered = raw.lowercased()
    var out = ""
    var lastWasDash = false
    for scalar in lowered.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
        out.unicodeScalars.append(scalar)
        lastWasDash = false
      } else if !lastWasDash, !out.isEmpty {
        out.append("-")
        lastWasDash = true
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "agent" : out
  }

  /// Picks `<stem>.md`, or `<stem>-2.md`, `-3`, … when a same-second write
  /// already claimed the name.
  private static func reserveFile(in directory: URL, stem: String) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var candidate = directory.appending(path: "\(stem).md")
    var counter = 2
    while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
      candidate = directory.appending(path: "\(stem)-\(counter).md")
      counter += 1
    }
    return candidate
  }

  private static func writeOrDiscard(_ text: String, to destination: URL) throws {
    do {
      try text.write(to: destination, atomically: true, encoding: .utf8)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }
}
