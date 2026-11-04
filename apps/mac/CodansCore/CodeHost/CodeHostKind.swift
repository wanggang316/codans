import Foundation

/// The kind of Code Host that serves a source repository's `origin` remote. Each kind has
/// one implementation of the app-tier `CodeHost` protocol. See ADR 0004.
///
/// Raw values are written to the Pull Request snapshot cache, so they must stay stable.
public nonisolated enum CodeHostKind: String, Codable, Sendable, CaseIterable, Hashable {
  case github
  case gitlab

  /// Name of the Code Host as the UI shows it.
  public var displayName: String {
    switch self {
    case .github: return "GitHub"
    case .gitlab: return "GitLab"
    }
  }

  /// Short UI label of a Pull Request on this Code Host ("PR" / "MR").
  public var pullRequestLabel: String {
    switch self {
    case .github: return "PR"
    case .gitlab: return "MR"
    }
  }

  /// Prefix of a Pull Request reference on this Code Host: `#6` on GitHub, `!6` on
  /// GitLab.
  public var referencePrefix: String {
    switch self {
    case .github: return "#"
    case .gitlab: return "!"
    }
  }

  /// Host of the public instance. A remote on this host resolves to this kind without
  /// asking the CLI which hosts it is logged in to.
  public var publicHost: String {
    switch self {
    case .github: return "github.com"
    case .gitlab: return "gitlab.com"
    }
  }

  /// Executable name of the CLI that codans calls for this Code Host.
  public var cliName: String {
    switch self {
    case .github: return "gh"
    case .gitlab: return "glab"
    }
  }

  /// Name of the CLI as the UI shows it.
  public var cliDisplayName: String {
    switch self {
    case .github: return "GitHub CLI"
    case .gitlab: return "GitLab CLI"
    }
  }

  /// Long UI name of a Pull Request on this Code Host, for sentences.
  public var pullRequestName: String {
    switch self {
    case .github: return "pull request"
    case .gitlab: return "merge request"
    }
  }
}
