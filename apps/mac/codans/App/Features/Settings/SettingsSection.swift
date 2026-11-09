import CodansCore
import Foundation

/// One row in the Settings window sidebar. The global cases are fixed-order; a
/// `project` row carries the `ProjectID` it binds to and is listed under the
/// sidebar's Project groups.
public enum SettingsSection: Hashable, Sendable {
  case general
  case globalCommands
  case agents
  case workflows
  /// Git Platforms (GitHub, GitLab): CLI availability and shared Pull Request defaults.
  /// Not the "Remote Hosts" pane, which lists machines.
  case gitPlatforms
  case hosts
  case worktree
  case terminal
  case notifications
  /// The LAN gateway for paired iOS devices.
  case remoteAccess
  case developer
  case shortcuts
  case updates
  case about

  /// One Project's settings on a single page: identity, editor, worktree,
  /// Git Platform, environment, commands, and lifecycle scripts. Sections
  /// render conditionally on `ProjectKind` inside `ProjectGeneralSettingsView`.
  case project(ProjectID)

  /// Global sidebar rows in display order, split into untitled groups: app
  /// preferences, agent tooling, then remote machines. The sidebar separates
  /// the groups with space only.
  public static let globalGroups: [[SettingsSection]] = [
    [
      .general, .gitPlatforms, .worktree, .terminal, .notifications, .globalCommands, .shortcuts,
      .updates, .about,
    ],
    [.agents, .developer, .workflows],
    [.hosts, .remoteAccess],
  ]

  /// Display name for global sidebar rows. Project-scoped cases return `nil` because
  /// their title needs a `ProjectID → name` resolution that only the window has access
  /// to; `SettingsWindowView` composes that string locally for the window-title binding.
  public var globalTitle: String? {
    switch self {
    case .general: return "General"
    case .globalCommands: return "Global Commands"
    case .agents: return "Agents"
    case .workflows: return "Workflows"
    case .gitPlatforms: return "Git Platforms"
    case .hosts: return "Remote Hosts"
    case .remoteAccess: return "Remote Access"
    case .worktree: return "Worktrees"
    case .terminal: return "Terminal"
    case .notifications: return "Notifications"
    case .developer: return "Integrations"
    case .shortcuts: return "Shortcuts"
    case .updates: return "Updates"
    case .about: return "About"
    case .project:
      return nil
    }
  }

  /// Extracts the backing `ProjectID` from any Project-scoped case; `nil` for globals.
  public var projectID: ProjectID? {
    switch self {
    case .project(let pid):
      return pid
    default:
      return nil
    }
  }
}
