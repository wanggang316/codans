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
  /// `true` when Pi, launched with `arguments` (the words after its
  /// executable, `nil` when they cannot be read) in `start`, trusts the
  /// project without asking. `agentDirectory` is Pi's config root
  /// (`~/.pi/agent` or `PI_CODING_AGENT_DIR`). `startExists` is `false`
  /// when `start` stands in for a new worktree whose own path is not known
  /// yet, so no saved decision can be matched to it.
  static func trusts(
    agentDirectory: URL, arguments: [String]?, start: URL, startExists: Bool,
    fileSystem: any SkillFileSystem = LocalSkillFileSystem()
  ) -> Bool {
    guard let launch = PiLaunchArguments(words: arguments) else { return false }
    if let approve = launch.approve { return approve }
    if launch.loadsExtensionFile { return false }
    guard let settings = readSettings(agentDirectory, fileSystem: fileSystem) else { return false }
    if !launch.noExtensions, hasUserExtensions(agentDirectory, settings: settings, fileSystem: fileSystem) {
      return false
    }
    guard startExists else { return false }
    switch savedDecision(agentDirectory, start: start, fileSystem: fileSystem) {
    case .trusted: return true
    case .untrusted, .unreadable: return false
    case .none: return settings["defaultProjectTrust"] as? String == "always"
    }
  }

  /// `<agent dir>/settings.json` as an object, `[:]` when it is missing,
  /// `nil` when it cannot be read.
  private static func readSettings(_ agentDirectory: URL, fileSystem: any SkillFileSystem) -> [String: Any]? {
    let file = agentDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
    guard let data = fileSystem.contents(of: file) else {
      return fileSystem.fileExists(at: file) ? nil : [:]
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// A user extension or package can decide trust, and codans cannot run
  /// it to see how.
  private static func hasUserExtensions(
    _ agentDirectory: URL, settings: [String: Any], fileSystem: any SkillFileSystem
  ) -> Bool {
    for key in ["extensions", "packages"] {
      if let list = settings[key] as? [Any], !list.isEmpty { return true }
      if settings[key] != nil, !(settings[key] is [Any]), !(settings[key] is NSNull) { return true }
    }
    let directory = agentDirectory.appending(path: "extensions", directoryHint: .isDirectory)
    let children = fileSystem.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) ?? []
    return children.contains { !$0.hasPrefix(".") }
  }

  private enum SavedDecision {
    case trusted, untrusted, none, unreadable
  }

  /// The decision saved for the canonical `start` or its nearest parent
  /// that has one. Pi stops with an error on a store that is not an object
  /// of `true`, `false`, or `null`.
  private static func savedDecision(
    _ agentDirectory: URL, start: URL, fileSystem: any SkillFileSystem
  ) -> SavedDecision {
    let file = agentDirectory.appending(path: "trust.json", directoryHint: .notDirectory)
    guard let data = fileSystem.contents(of: file) else {
      return fileSystem.fileExists(at: file) ? .unreadable : .none
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
    var current = canonicalPath(start, fileSystem: fileSystem)
    while true {
      if let decision = decisions[current] { return decision ? .trusted : .untrusted }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current || parent.isEmpty { return .none }
      current = parent
    }
  }

  /// The real path, as Pi's `realpathSync`, or the standardized path when
  /// it does not exist.
  private static func canonicalPath(_ url: URL, fileSystem: any SkillFileSystem) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return fileSystem.realPath(path) ?? normalized(path)
  }

  /// `path` without a trailing `/`. `NSString.standardizingPath` is not
  /// used: it drops the `/private` of `/private/var/...`, which Pi keeps.
  private static func normalized(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

/// The flags in a Pi profile's extra arguments that decide which skills Pi
/// loads, read the way Pi 1.5.0's `parseArgs` reads them: `--` ends the
/// options, and a flag that takes a value takes the next word even when it
/// looks like a flag (`--theme -a`).
nonisolated struct PiLaunchArguments: Equatable {
  /// The last `--approve` (`true`) or `--no-approve` (`false`).
  var approve: Bool?
  var noExtensions = false
  /// `-e` / `--extension` loads an extension that can decide trust.
  var loadsExtensionFile = false
  /// `-ns` / `--no-skills`: Pi loads no skills and expands no
  /// `/skill:name` call.
  var noSkills = false

  /// Flags that always take the next word.
  private static let valueFlags: Set<String> = [
    "--provider", "--model", "--api-key", "--system-prompt", "--append-system-prompt", "--name", "-n",
    "--session", "--session-id", "--fork", "--session-dir", "--models", "--tools", "-t", "--exclude-tools",
    "-xt", "--thinking", "--export", "--skill", "--prompt-template", "--theme",
  ]
  /// Flags that take the next word unless it starts with `-`.
  private static let optionalValueFlags: Set<String> = ["--mode", "--use-theme", "--tui-mode"]

  /// `nil` when the arguments are not plain words (`PlainShellWords`).
  init?(_ extraArguments: String) {
    self.init(words: PlainShellWords.split(extraArguments))
  }

  /// `nil` when the words cannot be read.
  init?(words: [String]?) {
    guard let words else { return nil }
    var index = 0
    while index < words.count, words[index] != "--" {
      let next = index + 1 < words.count ? words[index + 1] : nil
      apply(words[index], hasValue: next != nil)
      index += 1 + Self.valueWords(after: words[index], next: next)
    }
  }

  private mutating func apply(_ flag: String, hasValue: Bool) {
    switch flag {
    case "-a", "--approve": approve = true
    case "-na", "--no-approve": approve = false
    case "-ne", "--no-extensions": noExtensions = true
    case "-ns", "--no-skills": noSkills = true
    case "-e", "--extension": if hasValue { loadsExtensionFile = true }
    default: break
    }
  }

  /// How many of the following words `word` takes as its value: 0 or 1.
  private static func valueWords(after word: String, next: String?) -> Int {
    guard let next else { return 0 }
    let takes: Bool
    if word == "-e" || word == "--extension" || valueFlags.contains(word) {
      takes = true
    } else if word == "-p" || word == "--print" {
      takes = !next.hasPrefix("@") && (!next.hasPrefix("-") || next.hasPrefix("---"))
    } else if optionalValueFlags.contains(word) {
      takes = !next.hasPrefix("-")
    } else if word.hasPrefix("--"), !word.contains("=") {
      // `--list-models` and unknown flags, perhaps an extension's, take a
      // plain value. A known flag without a value taking a message word
      // here changes nothing: only words that start with `-` matter.
      takes = !next.hasPrefix("-") && !next.hasPrefix("@")
    } else {
      takes = false
    }
    return takes ? 1 : 0
  }
}
