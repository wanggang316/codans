import CodansIPC
import Foundation

public enum CLIArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
  case missingText
  case conflictingTextSources
  case invalidArgumentCount(message: String)
  case invalidScopeCount(expected: Int, actual: Int)
  case invalidKeyValue(message: String)
  case invalidValue(message: String)

  public var description: String {
    switch self {
    case .missingText:
      return "missing text; pass arguments or use --stdin"
    case .conflictingTextSources:
      return "pass either text arguments or --stdin, not both"
    case .invalidArgumentCount(let message):
      return message
    case .invalidScopeCount(let expected, let actual):
      return "expected \(expected) scope selection, got \(actual)"
    case .invalidKeyValue(let message), .invalidValue(let message):
      return message
    }
  }
}

public enum CLICommandText {
  public static func resolve(
    pieces: [String],
    stdin: String?,
    readsStdin: Bool
  ) throws -> String {
    if readsStdin {
      if !pieces.isEmpty {
        throw CLIArgumentError.conflictingTextSources
      }
      guard let stdin, !stdin.isEmpty else {
        throw CLIArgumentError.missingText
      }
      return stdin
    }

    guard !pieces.isEmpty else {
      throw CLIArgumentError.missingText
    }
    return pieces.joined(separator: " ")
  }

  public static func appendEnterIfNeeded(_ text: String, noEnter: Bool) -> String {
    guard !noEnter else { return text }
    if text.hasSuffix("\r") {
      return text
    }
    return text + "\r"
  }
}

public struct CLIResolvedSendInput: Equatable, Sendable {
  public let target: String
  public let text: String
}

public enum CLISendInput {
  public static func resolve(
    arguments: [String],
    explicitTarget: String?,
    stdin: String?,
    readsStdin: Bool,
    noEnter: Bool
  ) throws -> CLIResolvedSendInput {
    let target = explicitTarget

    if readsStdin {
      guard let stdin, !stdin.isEmpty else {
        throw CLIArgumentError.missingText
      }
      if target != nil, !arguments.isEmpty {
        throw CLIArgumentError.conflictingTextSources
      }
      if target == nil, arguments.count > 1 {
        throw CLIArgumentError.invalidArgumentCount(
          message: "expected at most one target when using --stdin"
        )
      }
      return CLIResolvedSendInput(
        target: target ?? arguments.first ?? "current",
        text: CLICommandText.appendEnterIfNeeded(stdin, noEnter: noEnter)
      )
    }

    if let target {
      guard !arguments.isEmpty else {
        throw CLIArgumentError.missingText
      }
      return CLIResolvedSendInput(
        target: target,
        text: CLICommandText.appendEnterIfNeeded(arguments.joined(separator: " "), noEnter: noEnter)
      )
    }

    switch arguments.count {
    case 0:
      throw CLIArgumentError.missingText
    case 1:
      return CLIResolvedSendInput(
        target: "current",
        text: CLICommandText.appendEnterIfNeeded(arguments[0], noEnter: noEnter)
      )
    default:
      return CLIResolvedSendInput(
        target: arguments[0],
        text: CLICommandText.appendEnterIfNeeded(arguments.dropFirst().joined(separator: " "), noEnter: noEnter)
      )
    }
  }
}

/// One `--project`, `--repo`, or `--remote` occurrence on `codans workspace
/// create` / `add`, in the order the user gave them (projects, then repos,
/// then remotes — ArgumentParser collects each option separately).
public enum CLIWorkspaceMemberSource: Equatable, Sendable {
  case project(String)
  case repo(String)
  case remote(String)

  /// `create` needs at least `minimum` members; `add` takes exactly one.
  public static func resolve(
    projects: [String],
    repos: [String],
    remotes: [String] = [],
    minimum: Int,
    maximum: Int? = nil
  ) throws -> [CLIWorkspaceMemberSource] {
    let sources =
      projects.map(CLIWorkspaceMemberSource.project) + repos.map(CLIWorkspaceMemberSource.repo)
      + remotes.map(CLIWorkspaceMemberSource.remote)
    if sources.count < minimum {
      throw CLIArgumentError.invalidArgumentCount(
        message:
          "pass at least \(minimum) repositor\(minimum == 1 ? "y" : "ies") with --project, --repo, or --remote (got \(sources.count))"
      )
    }
    if let maximum, sources.count > maximum {
      throw CLIArgumentError.invalidArgumentCount(
        message:
          "pass at most \(maximum) repositor\(maximum == 1 ? "y" : "ies") with --project, --repo, or --remote (got \(sources.count))"
      )
    }
    return sources
  }
}

/// The agent profile a `--agent` value names: its id, else its name
/// (case-insensitive). Disabled profiles are refused, as `agent launch`
/// refuses them, so a caller learns before it changes anything.
public enum CLIAgentProfileMatch {
  public static func resolve(
    _ selector: String, in profiles: [IPC.AgentProfileSummary]
  ) throws -> IPC.AgentProfileSummary {
    let wanted = selector.trimmingCharacters(in: .whitespaces)
    guard
      let profile = profiles.first(where: { $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame })
        ?? profiles.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
    else {
      let names = profiles.filter(\.isEnabled).map(\.name).joined(separator: ", ")
      throw CLIArgumentError.invalidValue(
        message: "no agent profile named \"\(wanted)\"" + (names.isEmpty ? "" : "; profiles: \(names)"))
    }
    guard profile.isEnabled else {
      throw CLIArgumentError.invalidValue(
        message: "agent profile \"\(profile.name)\" is disabled; enable it in Settings > Agents")
    }
    return profile
  }
}

public enum CLIBroadcastScopeSelection: Equatable, Sendable {
  case pane(String)
  case worktree(String)
  case label(String)

  public static func resolve(
    pane: String?,
    worktree: String?,
    label: String?
  ) throws -> CLIBroadcastScopeSelection {
    var selections: [CLIBroadcastScopeSelection] = []
    if let pane { selections.append(.pane(pane)) }
    if let worktree { selections.append(.worktree(worktree)) }
    if let label { selections.append(.label(label)) }
    guard selections.count == 1 else {
      throw CLIArgumentError.invalidScopeCount(expected: 1, actual: selections.count)
    }
    return selections[0]
  }
}

/// The session a send / send-key / capture targets. `--tab` names a Tab
/// (any of the three ids resolves to it); `--pane` names a Pane and means
/// that Pane's selected Tab — so `--pane current` is the caller's Pane's
/// selected Tab, not necessarily the caller's own Tab. A positional
/// target is a `--tab`.
public enum CLITargetSelection: Equatable, Sendable {
  case tab(String)
  case pane(String)

  /// At most one of `tab`, `pane`, `positional`; none → the calling Tab.
  public static func resolve(tab: String?, pane: String?, positional: String?) throws -> CLITargetSelection {
    let given = [tab, pane, positional].compactMap { $0 }
    guard given.count <= 1 else {
      throw CLIArgumentError.invalidArgumentCount(
        message: "pass one target: a positional tab, --tab, or --pane")
    }
    if let pane { return .pane(pane) }
    return .tab(tab ?? positional ?? "current")
  }

  /// The `--tab` / `--pane` value when one was given, for the commands
  /// whose positionals are split by `CLISendInput`.
  public static func explicit(tab: String?, pane: String?) throws -> CLITargetSelection? {
    if tab != nil, pane != nil {
      throw CLIArgumentError.invalidArgumentCount(message: "pass either --tab or --pane, not both")
    }
    if let pane { return .pane(pane) }
    return tab.map(CLITargetSelection.tab)
  }
}

/// Verbs that left their former location. The old spelling stays
/// parseable only to fail loudly with the new one, so a script written
/// against it never hits the wrong level silently.
public enum CLIMovedVerb {
  /// Former command path (space separated, without the executable) →
  /// the path that replaced it.
  public static let table: [String: String] = [
    "pane new": "tab new",
    "pane show": "tab show",
    "pane send": "tab send",
    "pane send-key": "tab send-key",
    "pane capture": "tab capture",
    "pane read": "tab read",
    "pane info": "tab info",
    "pane label": "tab label",
    "pane reset": "tab reset",
    "tab switch": "tab focus",
  ]

  public static func message(executable: String, from old: String) -> (message: String, hint: String) {
    let new = table[old] ?? old
    return (
      "`\(executable) \(old)` moved to `\(executable) \(new)`",
      "use `\(executable) \(new)`; `\(executable) pane` keeps only the layout verbs"
        + " (list, focus, split, close, resize, equalize, zoom)"
    )
  }
}

/// Repeated `--option name=value` arguments (`--role reviewer=auto`,
/// `--input branch=main`) folded into a map. A value may contain `=`; a
/// key may not be empty, and a key given twice is rejected rather than
/// silently letting the last one win, because both spellings look
/// deliberate on a command line.
public enum CLIKeyValuePairs {
  public static func parse(_ pairs: [String], option: String) throws -> [String: String] {
    var result: [String: String] = [:]
    for pair in pairs {
      guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
        throw CLIArgumentError.invalidKeyValue(message: "\(option) expects name=value, got \"\(pair)\"")
      }
      let key = String(pair[..<separator])
      guard result[key] == nil else {
        throw CLIArgumentError.invalidKeyValue(message: "\(option) \(key) given more than once")
      }
      result[key] = String(pair[pair.index(after: separator)...])
    }
    return result
  }
}
