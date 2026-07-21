import CodansCore
import Foundation

/// One resumable agent-CLI session discovered in the agent's own on-disk
/// history for a given worktree. `sessionID` is the identifier the agent's
/// resume invocation accepts (`claude --resume`, `codex resume`); `title`
/// is the best human-readable label the history store yields (first user
/// prompt for Claude Code, thread name for Codex).
nonisolated struct AgentSessionSummary: Identifiable, Equatable, Sendable {
  let agent: AgentKind
  let sessionID: String
  let title: String
  let updatedAt: Date

  var id: String { "\(agent.rawValue):\(sessionID)" }

  /// Compact display id. Claude ids are UUIDs whose leading bytes vary;
  /// Codex ids are ULIDs whose leading bytes encode the timestamp and so
  /// repeat across sessions — take the tail for those.
  var shortSessionID: String {
    switch agent {
    case .codex: return String(sessionID.suffix(8))
    default: return String(sessionID.prefix(8))
    }
  }
}

/// Sessions of one agent, newest first. Sections order by their newest
/// session so the most recently active agent leads the popover.
nonisolated struct AgentSessionGroup: Identifiable, Equatable, Sendable {
  let agent: AgentKind
  let sessions: [AgentSessionSummary]

  var id: String { agent.rawValue }
}

/// Maps an `AgentKind` + session id to the shell command that reattaches
/// the agent to that session. Only agents whose CLIs expose both a local
/// session store and a resume flag are supported; the scanner only emits
/// summaries for those kinds, so a `nil` at dispatch time signals a
/// programming error upstream, not a user-visible state.
nonisolated enum AgentSessionResume {
  static func command(agent: AgentKind, sessionID: String) -> String? {
    switch agent {
    case .claudeCode:
      return "claude --resume \(shellQuoted(sessionID))"
    case .codex:
      return "codex resume \(shellQuoted(sessionID))"
    case .pi, .opencode, .gemini, .cursorAgent, .cline, .copilot, .kimi, .droid, .amp:
      return nil
    }
  }

  /// Single-quote wrap with the standard `'\''` escape. Session ids are
  /// UUID/ULID-shaped today, but they originate from files we don't own —
  /// quote instead of trusting the charset.
  static func shellQuoted(_ raw: String) -> String {
    "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// Reads the local session stores of installed agent CLIs and lists the
/// sessions recorded against one worktree path. Pure filesystem reads —
/// callers spawn it off the main actor (`Task.detached`); the parsing
/// helpers take raw bytes so they stay unit-testable without fixtures on
/// the real home directory.
nonisolated enum AgentSessionHistoryScanner {
  /// Byte budgets when sniffing a session file. Claude session heads can
  /// carry multi-KB hook attachments before the first real user message;
  /// Codex first lines inline the full base instructions. Both fit well
  /// under these caps, and a miss only degrades the row title.
  private static let claudePrefixBytes = 512 * 1024
  private static let codexFirstLineBytes = 128 * 1024

  static func scan(
    worktreePath: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [AgentSessionGroup] {
    let path = normalized(worktreePath)
    var sessions: [AgentSessionSummary] = []
    sessions += claudeSessions(worktreePath: path, home: home)
    sessions += codexSessions(worktreePath: path, home: home)
    return grouped(sessions)
  }

  static func grouped(_ sessions: [AgentSessionSummary]) -> [AgentSessionGroup] {
    Dictionary(grouping: sessions, by: \.agent)
      .map { agent, group in
        AgentSessionGroup(
          agent: agent,
          sessions: group.sorted { $0.updatedAt > $1.updatedAt }
        )
      }
      .sorted {
        ($0.sessions.first?.updatedAt ?? .distantPast)
          > ($1.sessions.first?.updatedAt ?? .distantPast)
      }
  }

  /// Trailing-slash-insensitive path form so a cwd recorded as
  /// `/path/to/wt/` still matches the worktree's `/path/to/wt`.
  static func normalized(_ path: String) -> String {
    var result = path
    while result.count > 1, result.hasSuffix("/") {
      result.removeLast()
    }
    return result
  }

  // MARK: - Claude Code

  /// Claude Code munges the session cwd into a directory name under
  /// `~/.claude/projects/` by replacing every non-ASCII-alphanumeric
  /// character with `-` (verified against the on-disk store:
  /// `/a/.b` → `-a--b`).
  static func claudeProjectDirName(for worktreePath: String) -> String {
    String(worktreePath.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
  }

  private static func claudeSessions(
    worktreePath: String, home: URL
  ) -> [AgentSessionSummary] {
    let dir =
      home
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(claudeProjectDirName(for: worktreePath), isDirectory: true)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    return entries.compactMap { url in
      guard url.pathExtension == "jsonl" else { return nil }
      let stem = url.deletingPathExtension().lastPathComponent
      // Session files are named `<uuid>.jsonl`; anything else in the
      // directory (per-session tool caches, future formats) is skipped.
      guard UUID(uuidString: stem) != nil else { return nil }
      guard let modified = modificationDate(of: url) else { return nil }
      let title =
        claudeTitle(fromPrefix: filePrefix(of: url, maxBytes: claudePrefixBytes))
        ?? "Session \(stem.prefix(8))"
      return AgentSessionSummary(
        agent: .claudeCode, sessionID: stem, title: title, updatedAt: modified)
    }
  }

  /// First real user prompt in a Claude session prefix. Skips session
  /// metadata rows, sidechain/meta rows, and command/hook wrapper messages
  /// (`<command-name>`, `<local-command-stdout>`, system reminders) whose
  /// text starts with `<`, plus the "Caveat:" replay preamble.
  static func claudeTitle(fromPrefix data: Data) -> String? {
    let decoder = JSONDecoder()
    for lineData in data.split(separator: UInt8(ascii: "\n")) {
      guard
        let line = try? decoder.decode(ClaudeSessionLine.self, from: Data(lineData)),
        line.type == "user",
        line.isSidechain != true,
        line.isMeta != true,
        let text = line.message?.plainText
      else { continue }
      let cleaned = condensed(text)
      guard !cleaned.isEmpty, !cleaned.hasPrefix("<"), !cleaned.hasPrefix("Caveat:") else {
        continue
      }
      return cleaned
    }
    return nil
  }

  private struct ClaudeSessionLine: Decodable {
    let type: String?
    let isSidechain: Bool?
    let isMeta: Bool?
    let message: Message?

    struct Message: Decodable {
      let role: String?
      let content: Content?

      var plainText: String? {
        guard role == "user" else { return nil }
        switch content {
        case .text(let text):
          return text
        case .blocks(let blocks):
          let joined =
            blocks
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined(separator: " ")
          return joined.isEmpty ? nil : joined
        case nil:
          return nil
        }
      }
    }

    /// `message.content` is either a plain string (typed prompts) or an
    /// array of content blocks (structured turns).
    enum Content: Decodable {
      case text(String)
      case blocks([Block])

      init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
          self = .text(text)
        } else {
          self = .blocks(try container.decode([Block].self))
        }
      }
    }

    struct Block: Decodable {
      let type: String?
      let text: String?
    }
  }

  // MARK: - Codex

  struct CodexSessionMeta: Equatable {
    let id: String
    let cwd: String
  }

  private static func codexSessions(
    worktreePath: String, home: URL
  ) -> [AgentSessionSummary] {
    let root = home.appendingPathComponent(".codex", isDirectory: true)
    let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionsDir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    // Codex stores rollouts flat under date directories with no per-project
    // scoping; the global index maps ids to user-visible thread names.
    let indexData =
      (try? Data(contentsOf: root.appendingPathComponent("session_index.jsonl"))) ?? Data()
    let titles = codexThreadNames(from: indexData)
    var result: [AgentSessionSummary] = []
    for case let url as URL in enumerator {
      guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else {
        continue
      }
      guard
        let meta = codexSessionMeta(
          fromFirstLine: filePrefix(of: url, maxBytes: codexFirstLineBytes)),
        normalized(meta.cwd) == worktreePath,
        let modified = modificationDate(of: url)
      else { continue }
      let title =
        titles[meta.id].map(condensed).flatMap { $0.isEmpty ? nil : $0 }
        ?? "Session \(meta.id.suffix(8))"
      result.append(
        AgentSessionSummary(agent: .codex, sessionID: meta.id, title: title, updatedAt: modified))
    }
    return result
  }

  /// Parses the `session_meta` line that opens every Codex rollout file.
  static func codexSessionMeta(fromFirstLine data: Data) -> CodexSessionMeta? {
    let lineData: Data
    if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
      lineData = data.prefix(upTo: newline)
    } else if data.count < codexFirstLineBytes {
      // Single-line file read in full (meta written, no events yet).
      lineData = data
    } else {
      // Capped read with no newline — the meta line itself is truncated.
      return nil
    }
    guard
      let line = try? JSONDecoder().decode(CodexRolloutFirstLine.self, from: Data(lineData)),
      line.type == "session_meta",
      let id = line.payload?.id,
      let cwd = line.payload?.cwd
    else { return nil }
    return CodexSessionMeta(id: id, cwd: cwd)
  }

  /// Parses `~/.codex/session_index.jsonl` into an id → thread-name map.
  /// The index is append-only with the newest entry last, so later lines
  /// win on duplicate ids.
  static func codexThreadNames(from data: Data) -> [String: String] {
    var names: [String: String] = [:]
    let decoder = JSONDecoder()
    for lineData in data.split(separator: UInt8(ascii: "\n")) {
      guard
        let entry = try? decoder.decode(CodexIndexLine.self, from: Data(lineData)),
        let id = entry.id,
        let name = entry.threadName
      else { continue }
      names[id] = name
    }
    return names
  }

  private struct CodexRolloutFirstLine: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
      let id: String?
      let cwd: String?
    }
  }

  private struct CodexIndexLine: Decodable {
    let id: String?
    let threadName: String?

    enum CodingKeys: String, CodingKey {
      case id
      case threadName = "thread_name"
    }
  }

  // MARK: - Shared helpers

  private static func filePrefix(of url: URL, maxBytes: Int) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: maxBytes)) ?? Data()
  }

  private static func modificationDate(of url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }

  /// Single display line: newlines collapsed, whitespace trimmed, capped
  /// so a pasted wall of text can't blow up the row layout.
  private static func condensed(_ raw: String) -> String {
    let joined =
      raw
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return String(joined.prefix(200))
  }
}
