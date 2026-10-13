import CodansCore
import Foundation

/// Pure grouping, status, and trust logic for Settings → Workflows, kept out
/// of the view so it is testable without SwiftUI or a live `SettingsStore`.
/// The view does all the I/O (discovery scan, `NSWorkspace`, catalog reads)
/// and hands this enum plain values. `nonisolated` because the rules are
/// static and pure; the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION` would
/// otherwise pin the type (and its nested types) to the MainActor and force
/// every test onto it too — same reasoning as `EnvVarValidator`.
nonisolated enum WorkflowsSettingsLogic {

  /// One repository scope's workflows, grouped by the Project whose
  /// `<rootPath>/.codans/workflows` they came from.
  nonisolated struct RepositoryGroup: Equatable, Identifiable {
    var projectID: ProjectID
    var projectName: String
    var entries: [WorkflowCatalogEntry]

    var id: ProjectID { projectID }
  }

  /// A row's status glyph, derived from its diagnostics. An error wins over
  /// a warning — a file with errors can't start regardless of how many
  /// warnings it also carries.
  nonisolated enum RowStatus: Equatable {
    case ok
    case warnings(count: Int)
    case errors(count: Int)

    init(diagnostics: [WorkflowDiagnostic]) {
      let errorCount = diagnostics.filter(\.isError).count
      if errorCount > 0 {
        self = .errors(count: errorCount)
        return
      }
      self = diagnostics.isEmpty ? .ok : .warnings(count: diagnostics.count)
    }
  }

  /// The repository-trust state of one file, resolved against the user's
  /// `WorkflowSettings.trusted` grants. `notRequired` covers bundle/user
  /// scope files and repository files with no `run:` steps (see
  /// `WorkflowCatalogEntry.requiresTrust`).
  nonisolated enum TrustState: Equatable {
    case notRequired
    case trusted(grantedAt: Date)
    /// Granted once, but the file's bytes changed since — the grant no
    /// longer covers what would actually run.
    case outdated(grantedAt: Date)
    case notTrusted

    static func resolve(entry: WorkflowCatalogEntry, workflows: WorkflowSettings) -> TrustState {
      guard entry.requiresTrust else { return .notRequired }
      guard let grant = workflows.trusted.first(where: { $0.path == entry.path }) else {
        return .notTrusted
      }
      return grant.sha256 == entry.sha256 ? .trusted(grantedAt: grant.grantedAt) : .outdated(grantedAt: grant.grantedAt)
    }
  }

  /// One `launch` role's remembered binding. Resolved through the same
  /// requirements digest `WorkflowAdmission` uses at admission time, so a
  /// role whose requirements changed since the memory was written shows as
  /// not remembered here too — the memory would not be picked up on a run.
  nonisolated struct RoleBinding: Equatable, Identifiable {
    var role: WorkflowRole
    var profileName: String?

    var id: String { role.name }
    var isRemembered: Bool { profileName != nil }
  }

  /// The `launch` roles of a definition, each with its currently-valid
  /// remembered binding (if any) resolved to a profile display name.
  static func roleBindings(
    for entry: WorkflowCatalogEntry, workflows: WorkflowSettings, agents: AgentSettings
  ) -> [RoleBinding] {
    guard let definition = entry.definition else { return [] }
    return definition.roles.filter { $0.source == .launch }.map { role in
      let digest = WorkflowAdmission.requirementsDigest(for: role)
      let memory = workflows.binding(scope: entry.scope, workflowID: entry.id, role: role.name, digest: digest)
      let profileName = memory.flatMap { agents.profile(id: $0.profileID)?.displayName }
      return RoleBinding(role: role, profileName: profileName)
    }
  }

  /// Local git projects eligible to show a repository scope section:
  /// git-backed and local (excludes Server projects, whose `.codans/`
  /// lives on a remote host, and workspace roots, which are plain folders),
  /// with a main checkout that is not archived.
  static func eligibleRepositoryProjects(_ projects: [Project]) -> [Project] {
    projects
      .filter { project in
        guard project.kind == .gitRepo else { return false }
        let mainCheckoutArchived = project.worktrees.first { $0.path == project.rootPath }?.archived ?? false
        return !mainCheckoutArchived
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Repository groups to render: one per eligible project that actually has
  /// files under `.codans/workflows` — a project without the directory (or
  /// with an empty one) is skipped rather than shown as an empty section.
  /// `scanned` is keyed by `ProjectID`, already scanned by the caller.
  static func repositoryGroups(
    eligibleProjects: [Project], scanned: [ProjectID: [WorkflowCatalogEntry]]
  ) -> [RepositoryGroup] {
    eligibleProjects.compactMap { project in
      guard let entries = scanned[project.id], !entries.isEmpty else { return nil }
      return RepositoryGroup(
        projectID: project.id, projectName: project.name,
        entries: entries.sorted { $0.id < $1.id })
    }
  }
}
