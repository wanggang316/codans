import CodansCore
import Foundation

/// Agent-session history for a **Server-project** worktree: the agent CLIs'
/// session stores live in the HOST's home directory, so the local scanner
/// finds nothing. This scanner gathers the same facts over SSH — one call per
/// agent store, riding the shared ControlMaster — and reuses the local
/// scanner's parsers (`claudeTitle`, `codexSessionMeta`, `codexThreadNames`,
/// `grouped`) so the two paths can't drift.
///
/// Remote listing shape: each session is emitted as a marker line
/// `===CODANS-SESSION <epoch-mtime> <name>===` followed by a bounded prefix
/// of the file. Login-shell banners (dotfiles printing before the script's
/// output) are inert — parsing only starts at marker lines. `stat` is probed
/// in GNU (`-c`) then BSD (`-f`) form so Linux and macOS hosts both answer.
///
/// Resume needs no remote counterpart: the resume command is typed into a
/// pane whose shell already runs on the host.
nonisolated enum RemoteAgentSessionHistoryScanner {
  /// Per-file prefix cap. Smaller than the local scanner's 512 KiB Claude
  /// budget — this crosses the wire for up to `claudeSessionLimit` files per
  /// popover open; a miss only degrades the row title.
  static let prefixBytes = 131_072
  /// Newest-N cap applied host-side so an old worktree with hundreds of
  /// sessions doesn't ship megabytes per popover open.
  static let claudeSessionLimit = 25

  static let timeout: Duration = .seconds(25)
  static let maxOutputBytes = 16 * 1024 * 1024

  // MARK: - Entry

  static func scan(
    host: RemoteHost,
    worktreePath: String,
    runner: any CommandRunner = FoundationCommandRunner()
  ) async -> [AgentSessionGroup] {
    let path = AgentSessionHistoryScanner.normalized(worktreePath)
    // Sequential on purpose: two quick mux round-trips, and a deterministic
    // call order keeps the recording-runner tests simple.
    var sessions = await claudeSessions(host: host, worktreePath: path, runner: runner)
    sessions += await codexSessions(host: host, worktreePath: path, runner: runner)
    sessions += await ompSessions(host: host, worktreePath: path, runner: runner)
    return AgentSessionHistoryScanner.grouped(sessions)
  }

  // MARK: - Claude Code

  /// One round trip: newest `claudeSessionLimit` session files by mtime, each
  /// as a marker + prefix chunk. The project dir name contains only
  /// `[A-Za-z0-9-]` (see `claudeProjectDirName`), so direct interpolation is
  /// shell-inert.
  static func claudeScript(worktreePath: String) -> String {
    let dirName = AgentSessionHistoryScanner.claudeProjectDirName(for: worktreePath)
    return """
      cd "$HOME/.claude/projects/\(dirName)" 2>/dev/null || exit 0
      ( stat -c '%Y %n' *.jsonl 2>/dev/null || stat -f '%m %N' *.jsonl 2>/dev/null ) \
      | sort -rn | head -n \(claudeSessionLimit) | while IFS=' ' read -r mt f; do
        printf '===CODANS-SESSION %s %s===\\n' "$mt" "$f"
        head -c \(prefixBytes) "$f" 2>/dev/null
        printf '\\n'
      done
      """
  }

  private static func claudeSessions(
    host: RemoteHost, worktreePath: String, runner: any CommandRunner
  ) async -> [AgentSessionSummary] {
    guard
      let stdout = await runScript(
        claudeScript(worktreePath: worktreePath), host: host, runner: runner
      )
    else { return [] }
    return parseSessionChunks(stdout).compactMap { chunk in
      guard chunk.name.hasSuffix(".jsonl") else { return nil }
      let stem = String(chunk.name.dropLast(".jsonl".count))
      guard UUID(uuidString: stem) != nil else { return nil }
      let title =
        AgentSessionHistoryScanner.claudeTitle(fromPrefix: chunk.body)
        ?? "Session \(stem.prefix(8))"
      return AgentSessionSummary(
        agent: .claudeCode, sessionID: stem, title: title, updatedAt: chunk.mtime)
    }
  }

  // MARK: - Codex

  /// One round trip: the thread-name index, then every rollout whose first
  /// line mentions this worktree's cwd (host-side substring prefilter; the
  /// exact cwd match happens locally on the parsed meta). The cwd needle
  /// travels as a positional argument so the path never touches script
  /// parsing.
  static let codexScript = """
    printf '===CODANS-INDEX===\\n'
    cat "$HOME/.codex/session_index.jsonl" 2>/dev/null
    printf '\\n===CODANS-END-INDEX===\\n'
    [ -d "$HOME/.codex/sessions" ] || exit 0
    find "$HOME/.codex/sessions" -type f -name 'rollout-*.jsonl' 2>/dev/null \
    | while IFS= read -r f; do
      if head -c \(prefixBytes) "$f" 2>/dev/null | sed 1q | grep -F -q -- "$1"; then
        mt=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
        printf '===CODANS-SESSION %s %s===\\n' "$mt" "$f"
        head -c \(prefixBytes) "$f" 2>/dev/null | sed 1q
        printf '\\n'
      fi
    done
    """

  private static func codexSessions(
    host: RemoteHost, worktreePath: String, runner: any CommandRunner
  ) async -> [AgentSessionSummary] {
    guard
      let stdout = await runScript(
        codexScript, arguments: ["\"cwd\":\"\(worktreePath)\""], host: host, runner: runner
      )
    else { return [] }
    let titles = AgentSessionHistoryScanner.codexThreadNames(from: indexSection(of: stdout))
    return parseSessionChunks(stdout).compactMap { chunk in
      guard
        let meta = AgentSessionHistoryScanner.codexSessionMeta(fromFirstLine: chunk.body),
        AgentSessionHistoryScanner.normalized(meta.cwd) == worktreePath
      else { return nil }
      let title = titles[meta.id].flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(meta.id.suffix(8))"
      return AgentSessionSummary(
        agent: .codex, sessionID: meta.id, title: title, updatedAt: chunk.mtime)
    }
  }

  // MARK: - omp (oh-my-pi)

  /// One round trip: every omp session file whose header mentions this
  /// worktree's cwd (host-side substring prefilter on the `session` header
  /// line, exactly like the codex prefilter; the exact cwd match happens
  /// locally on the parsed meta). Only the two header lines cross the
  /// wire — message payloads start on line 3 and can be megabytes.
  static let ompScript = """
    [ -d "$HOME/.omp/agent/sessions" ] || exit 0
    find "$HOME/.omp/agent/sessions" -type f -name '*.jsonl' 2>/dev/null \
    | while IFS= read -r f; do
      if head -n 2 "$f" 2>/dev/null | sed -n 2p | grep -F -q -- "$1"; then
        mt=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
        printf '===CODANS-SESSION %s %s===\\n' "$mt" "$f"
        head -n 2 "$f" 2>/dev/null
        printf '\\n'
      fi
    done
    """

  private static func ompSessions(
    host: RemoteHost, worktreePath: String, runner: any CommandRunner
  ) async -> [AgentSessionSummary] {
    guard
      let stdout = await runScript(
        ompScript, arguments: ["\"cwd\":\"\(worktreePath)\""], host: host, runner: runner
      )
    else { return [] }
    return parseSessionChunks(stdout).compactMap { chunk in
      guard
        let meta = AgentSessionHistoryScanner.ompSessionMeta(fromPrefix: chunk.body),
        AgentSessionHistoryScanner.normalized(meta.cwd) == worktreePath
      else { return nil }
      let title =
        meta.title.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
          .flatMap { $0.isEmpty ? nil : $0 }
        ?? "Session \(meta.id.prefix(8))"
      return AgentSessionSummary(
        agent: .omp, sessionID: meta.id, title: title, updatedAt: chunk.mtime)
    }
  }

  // MARK: - Stream parsing (pure, testable)

  struct SessionChunk: Equatable {
    let mtime: Date
    let name: String
    let body: Data
  }

  static let sessionMarkerPrefix = "===CODANS-SESSION "
  static let markerSuffix = "==="

  /// Splits a marker-delimited stream into per-session chunks. Bytes before
  /// the first marker (login-shell banners, the codex index section) are
  /// ignored. A marker line is `===CODANS-SESSION <epoch> <name>===`; the
  /// chunk body runs to the next marker (or end of stream), with the
  /// trailing separator newline trimmed.
  static func parseSessionChunks(_ data: Data) -> [SessionChunk] {
    var chunks: [SessionChunk] = []
    var current: (mtime: Date, name: String)?
    var body = Data()

    func flush() {
      if let meta = current {
        if body.last == UInt8(ascii: "\n") { body.removeLast() }
        chunks.append(SessionChunk(mtime: meta.mtime, name: meta.name, body: body))
      }
      current = nil
      body = Data()
    }

    for lineData in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
      if let header = parseMarker(Data(lineData)) {
        flush()
        current = header
        continue
      }
      if current != nil {
        body.append(Data(lineData))
        body.append(UInt8(ascii: "\n"))
      }
    }
    flush()
    return chunks
  }

  /// `===CODANS-SESSION <epoch> <name>===` → (mtime, name), else nil. The
  /// name may itself contain spaces (absolute rollout paths never do today;
  /// defensive anyway).
  static func parseMarker(_ lineData: Data) -> (mtime: Date, name: String)? {
    guard let line = String(data: lineData, encoding: .utf8),
      line.hasPrefix(sessionMarkerPrefix),
      line.hasSuffix(markerSuffix)
    else { return nil }
    let payload = line.dropFirst(sessionMarkerPrefix.count).dropLast(markerSuffix.count)
    guard let space = payload.firstIndex(of: " "),
      let epoch = TimeInterval(payload[..<space])
    else { return nil }
    let name = String(payload[payload.index(after: space)...])
    guard !name.isEmpty else { return nil }
    // The remote file name is a path for codex rollouts; the callers only
    // need the basename.
    let base = name.split(separator: "/").last.map(String.init) ?? name
    return (Date(timeIntervalSince1970: epoch), base)
  }

  /// The bytes between the codex index markers, empty when absent.
  static func indexSection(of data: Data) -> Data {
    guard let text = String(data: data, encoding: .utf8),
      let start = text.range(of: "===CODANS-INDEX===\n"),
      let end = text.range(of: "\n===CODANS-END-INDEX==="),
      start.upperBound <= end.lowerBound
    else { return Data() }
    return Data(text[start.upperBound..<end.lowerBound].utf8)
  }

  // MARK: - Invocation

  /// Runs `script` under `/bin/sh` on the host (`sh -c <script> sh <args…>`,
  /// so `arguments` arrive as positionals). Returns stdout, or nil on any
  /// failure — history is best-effort and an unreachable host must read as
  /// "no sessions", not an error.
  private static func runScript(
    _ script: String,
    arguments: [String] = [],
    host: RemoteHost,
    runner: any CommandRunner
  ) async -> Data? {
    let (executable, sshArguments) = SSHCommand.invocation(
      host: host,
      executable: "/bin/sh",
      arguments: ["-c", script, "sh"] + arguments,
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    let outcome = await runner.run(
      executable: executable,
      arguments: sshArguments,
      env: ProcessInfo.processInfo.environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: timeout,
      maxOutputBytes: maxOutputBytes
    )
    guard case .exited(let code, let stdout, _, _) = outcome, code == 0 else { return nil }
    return stdout
  }
}
