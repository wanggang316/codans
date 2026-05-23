import Foundation
import TouchCodeCore

/// One row in the Settings window sidebar. The global cases are fixed-order; the
/// Project-scoped cases carry the `ProjectID` they bind to and are surfaced under the
/// sidebar's "Projects" DisclosureGroup.
public enum SettingsSection: Hashable, Sendable {
  case general
  case github
  case worktree
  case terminal
  case notifications
  case developer
  case shortcuts
  case updates
  case about

  // MARK: - Project-scoped sub-panes

  /// Project-universal settings: editor, git viewer (git-only), worktree
  /// (git-only), GitHub (git-only), environment variables. Sections render
  /// conditionally on `ProjectKind` inside `ProjectGeneralSettingsView`.
  case projectGeneral(ProjectID)
  /// User-defined scripts + worktree-lifecycle scripts (git-only Section).
  case projectScripts(ProjectID)

  /// Canonical iteration order for global sidebar rows.
  public static let globals: [SettingsSection] = [
    .general, .github, .worktree, .terminal, .notifications, .developer, .shortcuts, .updates, .about,
  ]

  /// Display name for global sidebar rows. Project-scoped cases return `nil` because
  /// their title needs a `ProjectID → name` resolution that only the window has access
  /// to; `SettingsWindowView` composes that string locally for the window-title binding.
  public var globalTitle: String? {
    switch self {
    case .general: return "General"
    case .github: return "GitHub"
    case .worktree: return "Worktrees"
    case .terminal: return "Terminal"
    case .notifications: return "Notifications"
    case .developer: return "Developer"
    case .shortcuts: return "Shortcuts"
    case .updates: return "Updates"
    case .about: return "About"
    case .projectGeneral, .projectScripts:
      return nil
    }
  }

  /// Extracts the backing `ProjectID` from any Project-scoped case; `nil` for globals.
  public var projectID: ProjectID? {
    switch self {
    case .projectGeneral(let pid),
      .projectScripts(let pid):
      return pid
    default:
      return nil
    }
  }
}

extension SettingsSection {
  /// Sub-rows rendered under a Project. Same set for `gitRepo` and `dir` —
  /// kind difference is encoded as Section-level conditional rendering inside
  /// `ProjectGeneralSettingsView`. The `kind` parameter is preserved so callers
  /// do not need a signature change if the policy ever splits again.
  public static func subrows(for kind: ProjectKind, projectID: ProjectID) -> [SettingsSection] {
    _ = kind
    return [
      .projectGeneral(projectID),
      .projectScripts(projectID),
    ]
  }

  /// Human-readable row title for a Project-scoped sub-pane. Used by the sidebar row
  /// builder. Returns `nil` for global sections.
  public var projectSubrowTitle: String? {
    switch self {
    case .projectGeneral: return "General"
    case .projectScripts: return "Scripts"
    default: return nil
    }
  }
}
