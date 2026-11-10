import CodansCore
import Foundation

/// Why the skills of a remote project could not be read. `reason` is shown
/// on the disabled Skills button.
nonisolated struct RemoteSkillReadError: Error, Equatable, Sendable {
  var reason: String
}

/// Reads the Agent Skills a profile's agent can call on a remote host: the
/// same Skill Location rules as a local project (ADR 0010), resolved
/// against the host's `HOME` and file system. The resolver and the scanner
/// run on a `SkillFileSnapshot`; each round sends the reads it could not
/// answer to the host in one POSIX `sh` script over the shared SSH
/// ControlMaster (`SSHCommand.invocation`), so a load costs a few round
/// trips, not one per file.
nonisolated struct RemoteSkillReader: Sendable {
  /// Rounds after the first one. Claude Code needs three (config files and
  /// the repository walk, the plugins, their skills); the rest is margin.
  static let maxRounds = 8
  static let timeout: Duration = .seconds(20)
  static let maxOutputBytes = 16 * 1024 * 1024
  /// A config file larger than this reads as unreadable: it gives no say,
  /// as a file Claude Code or Codex cannot parse.
  static let fileLimit = 1024 * 1024
  /// The part of each `SKILL.md` that crosses the wire. The frontmatter is
  /// at the top; a longer one reads as broken and lists the folder name.
  static let skillPrefixBytes = 64 * 1024

  let host: RemoteHost
  var runner: any CommandRunner = FoundationCommandRunner()

  /// The skills `profile`'s agent can call when it starts in the remote
  /// directory `projectStart`. `createsWorktree` is `true` when the agent
  /// starts in a worktree that does not exist yet: its project files are
  /// unknown, so only user skills are listed (ADR 0010).
  func load(
    profile: AgentProfile, projectStart: String?, createsWorktree: Bool,
    stateDirectory: URL = AppDirectories.stateDirectory()
  ) async throws(RemoteSkillReadError) -> [AgentSkillEntry] {
    let snapshot = SkillFileSnapshot()
    let system = try await fetch([], into: snapshot)
    let home = URL(fileURLWithPath: system.home, isDirectory: true)
    let precedence = profile.descriptor.skillLocation.precedence
    let start = createsWorktree ? nil : projectStart.map { URL(fileURLWithPath: $0, isDirectory: true) }
    do {
      let entries = try await snapshot.settle(maxRounds: Self.maxRounds) {
        let directories =
          createsWorktree
          ? SkillLocationResolver.userDirectories(for: profile, userHome: home, stateDirectory: stateDirectory)
          : SkillLocationResolver.directories(
            for: profile, projectStart: start, userHome: home, stateDirectory: stateDirectory,
            managedSettings: SkillLocationResolver.claudeManagedSettings(kernel: system.kernel),
            fileSystem: snapshot)
        return SkillScanner.scanSync(directories, precedence: precedence, fileSystem: snapshot)
      } fetch: { requests in
        _ = try await self.fetch(requests, into: snapshot)
      }
      guard let entries else {
        throw RemoteSkillReadError(reason: "Reading skills on \(host.authority) did not finish")
      }
      return entries
    } catch let error as RemoteSkillReadError {
      throw error
    } catch {
      throw RemoteSkillReadError(reason: error.localizedDescription)
    }
  }

  // MARK: - Round trip

  struct System: Equatable {
    var home: String
    var kernel: String
  }

  /// Sends `requests` to the host and puts the answers into `snapshot`.
  private func fetch(
    _ requests: [SkillFileSnapshot.Request], into snapshot: SkillFileSnapshot
  ) async throws(RemoteSkillReadError) -> System {
    let (executable, arguments) = SSHCommand.invocation(
      host: host,
      executable: "/bin/sh",
      arguments: ["-c", Self.script, "sh", String(Self.fileLimit), String(Self.skillPrefixBytes)]
        + Self.arguments(for: requests),
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions
    )
    let outcome = await runner.run(
      executable: executable,
      arguments: arguments,
      env: ProcessInfo.processInfo.environment,
      cwd: URL(fileURLWithPath: NSHomeDirectory()),
      timeout: Self.timeout,
      maxOutputBytes: Self.maxOutputBytes
    )
    switch outcome {
    case .exited(0, let stdout, _, false):
      guard let system = Self.apply(stdout, requests: requests, to: snapshot) else {
        throw RemoteSkillReadError(reason: "\(host.authority) sent a reply codans cannot read")
      }
      return system
    case .exited(0, _, _, true):
      throw RemoteSkillReadError(reason: "The skills on \(host.authority) are too large to list")
    case .exited(let code, _, let stderr, _):
      let message = RemoteGitService.lastNonEmptyLine(of: String(data: stderr, encoding: .utf8) ?? "")
      let reason = code == 255 ? "Could not connect to \(host.authority)" : "Reading skills on \(host.authority) failed"
      throw RemoteSkillReadError(reason: message.isEmpty ? reason : "\(reason): \(message)")
    case .timedOut:
      throw RemoteSkillReadError(reason: "\(host.authority) did not answer in time")
    case .spawnFailed(let reason):
      throw RemoteSkillReadError(reason: "Could not start ssh: \(reason)")
    }
  }

  static func arguments(for requests: [SkillFileSnapshot.Request]) -> [String] {
    requests.flatMap { request -> [String] in
      switch request {
      case .file(let path): ["F", path]
      case .directory(let path): ["D", path]
      case .realPath(let path): ["R", path]
      }
    }
  }

  // MARK: - Script

  static let replyMarker = "===CODANS-SKILL-FILES==="

  /// POSIX `sh`. `$1` is the file size limit, `$2` the `SKILL.md` prefix
  /// size, then one `<op> <path>` pair per request (paths travel as
  /// arguments, never as script text). After `replyMarker` each answer is a
  /// record: a `<kind> <request index> <byte count>` line, the bytes, and a
  /// newline. `h` and `k` (index 0) are `$HOME` and `uname -s`. A file is
  /// `f` (bytes), `x` (there but unreadable), or `m` (missing); a
  /// directory `d`, then `c` per child name and `s` for that child's
  /// `SKILL.md`; a real path `r`. Lines before the marker are login-shell
  /// banners. `wc -c` and `head -c` are byte exact, so any byte can cross.
  static let script = #"""
    limit=$1; prefix=$2; shift 2
    put() { printf '%s %s %s\n' "$1" "$2" "$3"; }
    none() { put "$1" "$2" 0; printf '\n'; }
    str() { n=$(printf '%s' "$3" | wc -c | tr -d ' \t'); put "$1" "$2" "$n"; printf '%s\n' "$3"; }
    bytes() { put "$1" "$2" "$4"; head -c "$4" "$3" 2>/dev/null; printf '\n'; }
    printf '%s\n' '===CODANS-SKILL-FILES==='
    str h 0 "$HOME"
    str k 0 "$(uname -s 2>/dev/null)"
    i=0
    while [ "$#" -ge 2 ]; do
      op=$1; p=$2; shift 2
      case $op in
        F)
          if [ -f "$p" ] && [ -r "$p" ] && n=$(wc -c < "$p" 2>/dev/null | tr -d ' \t') \
            && [ -n "$n" ] && [ "$n" -le "$limit" ]; then
            bytes f "$i" "$p" "$n"
          elif [ -e "$p" ]; then none x "$i"
          else none m "$i"; fi ;;
        D)
          if [ -d "$p" ] && [ -r "$p" ] && [ -x "$p" ]; then
            none d "$i"
            for c in "$p"/* "$p"/.[!.]* "$p"/..?*; do
              [ -e "$c" ] || [ -L "$c" ] || continue
              str c "$i" "${c##*/}"
              s=$c/SKILL.md
              if [ -f "$s" ] && [ -r "$s" ]; then
                bytes s "$i" "$s" "$(head -c "$prefix" "$s" 2>/dev/null | wc -c | tr -d ' \t')"
              fi
            done
          else none m "$i"; fi ;;
        R)
          if r=$(cd -- "$p" 2>/dev/null && pwd -P); then str r "$i" "$r"; else none m "$i"; fi ;;
      esac
      i=$((i + 1))
    done
    """#

  // MARK: - Reply

  /// Puts the answers of `reply` into `snapshot` and returns the host's
  /// `HOME` and kernel, or `nil` when the reply is cut short, does not
  /// answer every request, or has no absolute `HOME`.
  static func apply(
    _ reply: Data, requests: [SkillFileSnapshot.Request], to snapshot: SkillFileSnapshot
  ) -> System? {
    guard let records = records(in: reply) else { return nil }
    var answers = Answers()
    for record in records {
      guard answers.add(record) else { return nil }
    }
    guard let home = answers.home, home.hasPrefix("/"), answers.store(requests, into: snapshot) else {
      return nil
    }
    return System(home: home, kernel: answers.kernel)
  }

  /// The answers of one reply by request index.
  private struct Answers {
    var home: String?
    var kernel = ""
    var files: [Int: SkillFileSnapshot.FileAnswer] = [:]
    var directories: [Int: [SkillFileSnapshot.Child]?] = [:]
    var realPaths: [Int: String?] = [:]
    /// The last child name was not UTF-8, so it and its `SKILL.md` are
    /// left out: no path codans builds can name it.
    var skipsChild = false

    mutating func add(_ record: Record) -> Bool {
      let text = String(data: record.bytes, encoding: .utf8)
      switch record.kind {
      case "h": home = text
      case "k": kernel = text ?? ""
      case "f": files[record.index] = .data(record.bytes)
      case "x": files[record.index] = .unreadable
      case "d": directories[record.index] = .some([])
      case "c":
        guard case .some(.some(var children)) = directories[record.index] else { return false }
        skipsChild = text == nil
        if let text { children.append(SkillFileSnapshot.Child(name: text)) }
        directories[record.index] = .some(children)
      case "s":
        guard case .some(.some(var children)) = directories[record.index] else { return false }
        guard !skipsChild else { return true }
        guard !children.isEmpty else { return false }
        children[children.count - 1].skill = record.bytes
        directories[record.index] = .some(children)
      case "r": realPaths[record.index] = .some(text)
      case "m":
        files[record.index] = .missing
        directories[record.index] = .some(nil)
        realPaths[record.index] = .some(nil)
      default: return false
      }
      return true
    }

    /// `false` when a request has no answer.
    func store(_ requests: [SkillFileSnapshot.Request], into snapshot: SkillFileSnapshot) -> Bool {
      for (index, request) in requests.enumerated() {
        switch request {
        case .file(let path):
          guard let answer = files[index] else { return false }
          snapshot.setFile(path, answer)
        case .directory(let path):
          guard let answer = directories[index] else { return false }
          snapshot.setDirectory(path, answer)
        case .realPath(let path):
          guard let answer = realPaths[index] else { return false }
          snapshot.setRealPath(path, answer)
        }
      }
      return true
    }
  }

  struct Record: Equatable {
    var kind: String
    var index: Int
    var bytes: Data
  }

  /// The records after `replyMarker`, or `nil` when there is no marker or
  /// a record is cut short.
  static func records(in reply: Data) -> [Record]? {
    let newline = UInt8(ascii: "\n")
    guard let marker = reply.firstRange(of: Data((replyMarker + "\n").utf8)) else { return nil }
    var records: [Record] = []
    var cursor = marker.upperBound
    while cursor < reply.endIndex {
      guard let end = reply[cursor...].firstIndex(of: newline) else { return nil }
      let fields = (String(data: reply[cursor..<end], encoding: .utf8) ?? "").split(separator: " ")
      guard fields.count == 3, let index = Int(fields[1]), let count = Int(fields[2]), count >= 0,
        reply.distance(from: end, to: reply.endIndex) > count + 1
      else { return nil }
      let start = reply.index(after: end)
      let stop = reply.index(start, offsetBy: count)
      guard reply[stop] == newline else { return nil }
      records.append(Record(kind: String(fields[0]), index: index, bytes: Data(reply[start..<stop])))
      cursor = reply.index(after: stop)
    }
    return records
  }
}
