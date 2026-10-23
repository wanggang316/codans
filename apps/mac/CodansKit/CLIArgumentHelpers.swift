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
    explicitPane: String?,
    stdin: String?,
    readsStdin: Bool,
    noEnter: Bool
  ) throws -> CLIResolvedSendInput {
    let target = explicitPane

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
  case tab(String)
  case worktree(String)
  case label(String)

  public static func resolve(
    tab: String?,
    worktree: String?,
    label: String?
  ) throws -> CLIBroadcastScopeSelection {
    var selections: [CLIBroadcastScopeSelection] = []
    if let tab { selections.append(.tab(tab)) }
    if let worktree { selections.append(.worktree(worktree)) }
    if let label { selections.append(.label(label)) }
    guard selections.count == 1 else {
      throw CLIArgumentError.invalidScopeCount(expected: 1, actual: selections.count)
    }
    return selections[0]
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
