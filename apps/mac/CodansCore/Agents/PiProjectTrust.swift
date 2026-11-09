import Darwin
import Foundation

/// Whether Pi will trust the project it starts in. Pi loads project skills
/// (`.pi/skills`, project `.agents/skills`) only in a trusted project, and
/// in an untrusted one a `/skill:name` call to them does not run. Pi
/// decides in this order: `--approve` / `--no-approve`, then an extension
/// that handles `project_trust`, then the nearest saved decision in
/// `<agent dir>/trust.json`, then `defaultProjectTrust` (default `ask`).
/// codans offers project skills only when that order gives "trusted"
/// without a question at startup; anything it cannot be sure of gives no
/// project skills (ADR 0010; design doc: Agent Skill Completion → Probe).
nonisolated enum PiProjectTrust {
  /// `true` when Pi, launched with `extraArguments` in `start`, trusts the
  /// project without asking. `agentDirectory` is Pi's config root
  /// (`~/.pi/agent` or `PI_CODING_AGENT_DIR`). `startExists` is `false`
  /// when `start` stands in for a new worktree whose own path is not known
  /// yet, so no saved decision can be matched to it.
  static func trusts(
    agentDirectory: URL, extraArguments: String, start: URL, startExists: Bool
  ) -> Bool {
    guard let words = PlainShellWords.split(extraArguments) else { return false }
    var approve: Bool?
    var noExtensions = false
    for word in words {
      switch word {
      case "-a", "--approve": approve = true
      case "-na", "--no-approve": approve = false
      case "-ne", "--no-extensions": noExtensions = true
      case "-e", "--extension": return false
      default: if word.hasPrefix("--extension=") { return false }
      }
    }
    if let approve { return approve }
    guard let settings = readSettings(agentDirectory) else { return false }
    if !noExtensions, hasUserExtensions(agentDirectory, settings: settings) { return false }
    guard startExists else { return false }
    switch savedDecision(agentDirectory, start: start) {
    case .trusted: return true
    case .untrusted, .unreadable: return false
    case .none: return settings["defaultProjectTrust"] as? String == "always"
    }
  }

  /// `<agent dir>/settings.json` as an object, `[:]` when it is missing,
  /// `nil` when it cannot be read.
  private static func readSettings(_ agentDirectory: URL) -> [String: Any]? {
    let file = agentDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
    guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else {
      return FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) ? nil : [:]
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// A user extension or package can decide trust, and codans cannot run
  /// it to see how.
  private static func hasUserExtensions(_ agentDirectory: URL, settings: [String: Any]) -> Bool {
    for key in ["extensions", "packages"] {
      if let list = settings[key] as? [Any], !list.isEmpty { return true }
      if settings[key] != nil, !(settings[key] is [Any]), !(settings[key] is NSNull) { return true }
    }
    let directory = agentDirectory.appending(path: "extensions", directoryHint: .isDirectory)
    let children = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    return children.contains { !$0.hasPrefix(".") }
  }

  private enum SavedDecision {
    case trusted, untrusted, none, unreadable
  }

  /// The decision saved for the canonical `start` or its nearest parent
  /// that has one. Pi stops with an error on a store that is not an object
  /// of `true`, `false`, or `null`.
  private static func savedDecision(_ agentDirectory: URL, start: URL) -> SavedDecision {
    let file = agentDirectory.appending(path: "trust.json", directoryHint: .notDirectory)
    let path = file.path(percentEncoded: false)
    guard let data = FileManager.default.contents(atPath: path) else {
      return FileManager.default.fileExists(atPath: path) ? .unreadable : .none
    }
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
    var decisions: [String: Bool] = [:]
    for (key, value) in object {
      if value is NSNull { continue }
      guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        return .unreadable
      }
      decisions[normalized(key)] = number.boolValue
    }
    var current = canonicalPath(start)
    while true {
      if let decision = decisions[current] { return decision ? .trusted : .untrusted }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current || parent.isEmpty { return .none }
      current = parent
    }
  }

  /// The real path, as Pi's `realpathSync`, or the standardized path when
  /// it does not exist.
  private static func canonicalPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    guard let resolved = realpath(path, nil) else { return normalized(path) }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// `path` without a trailing `/`. `NSString.standardizingPath` is not
  /// used: it drops the `/private` of `/private/var/...`, which Pi keeps.
  private static func normalized(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
