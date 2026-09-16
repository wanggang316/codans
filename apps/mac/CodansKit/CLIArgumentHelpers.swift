import Foundation

public enum CLIArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
  case missingText
  case conflictingTextSources
  case invalidArgumentCount(message: String)
  case invalidScopeCount(expected: Int, actual: Int)

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

/// How `codans workspace create` / `add` check members out, from the three
/// mode flags. `--existing` (an existing local branch), `--track` (the
/// remote-tracking `origin/<branch>`), and `--ref <remote>/<branch>` are
/// exclusive; `--reset-local` only means something with one of the latter
/// two.
public struct CLIWorkspaceCheckoutFlags: Equatable, Sendable {
  public var useExistingBranch: Bool?
  public var trackRemote: Bool?
  public var remoteRef: String?
  public var resetLocalBranch: Bool?

  public static func resolve(
    existing: Bool,
    track: Bool,
    ref: String?,
    resetLocal: Bool
  ) throws -> CLIWorkspaceCheckoutFlags {
    let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
    let modes = [existing, track, ref?.isEmpty == false].filter { $0 }.count
    if modes > 1 {
      throw CLIArgumentError.invalidArgumentCount(
        message: "--existing, --track, and --ref are exclusive; pass one")
    }
    if let ref, !ref.isEmpty, !ref.contains("/") || ref.hasPrefix("/") || ref.hasSuffix("/") {
      throw CLIArgumentError.invalidArgumentCount(
        message: "--ref expects <remote>/<branch>, got \(ref)")
    }
    if resetLocal, !track, ref?.isEmpty != false {
      throw CLIArgumentError.invalidArgumentCount(
        message: "--reset-local needs --track or --ref")
    }
    return CLIWorkspaceCheckoutFlags(
      useExistingBranch: existing ? true : nil,
      trackRemote: track ? true : nil,
      remoteRef: ref?.isEmpty == false ? ref : nil,
      resetLocalBranch: resetLocal ? true : nil)
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
