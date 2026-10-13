import CodansCore
import Foundation
import Testing

@testable import Codans

/// Pins the Workflows Settings pane's pure logic: row status from
/// diagnostics, repository-trust state (including "outdated"), remembered
/// `launch` bindings via the requirements digest, and which projects /
/// scans surface a repository section. No SwiftUI, no live `SettingsStore`
/// — fixtures built directly, mirroring `WorkflowEngineTests`' style.
struct WorkflowsSettingsLogicTests {

  // MARK: - Fixtures

  static func definition(
    id: String = "wf", roles: [WorkflowRole] = [], hasRunStep: Bool = false
  ) -> WorkflowDefinition {
    let steps: [WorkflowStep] =
      hasRunStep
      ? [WorkflowStep(id: "run-1", verb: .run(WorkflowRunCommand(command: .literal("echo hi"))))]
      : [WorkflowStep(id: "notify-1", verb: .notify(.literal("done")))]
    return WorkflowDefinition(id: id, name: id, roles: roles, steps: steps)
  }

  static func entry(
    id: String = "wf", scope: WorkflowScope = .repo, roles: [WorkflowRole] = [], hasRunStep: Bool = false,
    diagnostics: [WorkflowDiagnostic] = [], path: String? = nil, sha256: String = "sha-abc"
  ) -> WorkflowCatalogEntry {
    WorkflowCatalogEntry(
      id: id, scope: scope, path: path ?? "/repo/.codans/workflows/\(id).workflow.yaml",
      yaml: "name: \(id)", sha256: sha256,
      definition: Self.definition(id: id, roles: roles, hasRunStep: hasRunStep),
      diagnostics: diagnostics)
  }

  // MARK: - RowStatus

  @Test
  func rowStatusIsOKWithNoDiagnostics() {
    #expect(WorkflowsSettingsLogic.RowStatus(diagnostics: []) == .ok)
  }

  @Test
  func rowStatusCountsWarningsWhenThereAreNoErrors() {
    let diagnostics: [WorkflowDiagnostic] = [
      .warning("unknown_agent", "unknown agent `foo` is ignored"),
      .warning("unknown_agent", "unknown agent `bar` is ignored"),
    ]
    #expect(WorkflowsSettingsLogic.RowStatus(diagnostics: diagnostics) == .warnings(count: 2))
  }

  @Test
  func rowStatusErrorsWinOverWarnings() {
    let diagnostics: [WorkflowDiagnostic] = [
      .warning("unknown_agent", "unknown agent `foo` is ignored"),
      .error("missing_key", "`name` is required"),
    ]
    #expect(WorkflowsSettingsLogic.RowStatus(diagnostics: diagnostics) == .errors(count: 1))
  }

  // MARK: - TrustState

  @Test
  func trustStateNotRequiredWhenEntryHasNoRunSteps() {
    let entry = Self.entry(hasRunStep: false)
    #expect(WorkflowsSettingsLogic.TrustState.resolve(entry: entry, workflows: .default) == .notRequired)
  }

  @Test
  func trustStateNotRequiredForNonRepositoryScopes() {
    let entry = Self.entry(scope: .user, hasRunStep: true)
    #expect(WorkflowsSettingsLogic.TrustState.resolve(entry: entry, workflows: .default) == .notRequired)
  }

  @Test
  func trustStateNotTrustedWithNoGrant() {
    let entry = Self.entry(hasRunStep: true)
    #expect(WorkflowsSettingsLogic.TrustState.resolve(entry: entry, workflows: .default) == .notTrusted)
  }

  @Test
  func trustStateTrustedWhenShaMatchesTheGrant() {
    let entry = Self.entry(hasRunStep: true, sha256: "same-sha")
    var settings = WorkflowSettings.default
    let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
    settings.trust(path: entry.path, sha256: "same-sha", at: grantedAt)
    #expect(
      WorkflowsSettingsLogic.TrustState.resolve(entry: entry, workflows: settings) == .trusted(grantedAt: grantedAt))
  }

  @Test
  func trustStateOutdatedWhenTheFileChangedSinceTheGrant() {
    let entry = Self.entry(hasRunStep: true, sha256: "new-sha")
    var settings = WorkflowSettings.default
    let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
    settings.trust(path: entry.path, sha256: "old-sha", at: grantedAt)
    #expect(
      WorkflowsSettingsLogic.TrustState.resolve(entry: entry, workflows: settings) == .outdated(grantedAt: grantedAt))
  }

  // MARK: - RoleBinding

  @Test
  func roleBindingsOnlyIncludeLaunchRoles() {
    let launchRole = WorkflowRole(name: "reviewer", source: .launch)
    let currentRole = WorkflowRole(name: "author", source: .current)
    let entry = Self.entry(roles: [launchRole, currentRole])
    let bindings = WorkflowsSettingsLogic.roleBindings(for: entry, workflows: .default, agents: .default)
    #expect(bindings.map(\.role.name) == ["reviewer"])
    #expect(bindings.first?.isRemembered == false)
  }

  @Test
  func roleBindingsResolveTheRememberedProfileName() {
    let role = WorkflowRole(name: "reviewer", source: .launch, agents: [.claudeCode])
    let entry = Self.entry(id: "review-loop", scope: .user, roles: [role])
    let profile = AgentProfile(id: UUID(), kind: .claudeCode, name: "Reviewer")
    var settings = WorkflowSettings.default
    settings.remember(
      WorkflowBindingMemory(
        scope: .user, workflowID: "review-loop", role: "reviewer",
        requirementsDigest: WorkflowAdmission.requirementsDigest(for: role), profileID: profile.id))
    let agents = AgentSettings(profiles: [profile])
    let bindings = WorkflowsSettingsLogic.roleBindings(for: entry, workflows: settings, agents: agents)
    #expect(bindings.first?.profileName == "Reviewer")
    #expect(bindings.first?.isRemembered == true)
  }

  @Test
  func roleBindingsIgnoreAMemoryWhoseRequirementsChanged() {
    let originalRole = WorkflowRole(name: "reviewer", source: .launch, agents: [.claudeCode])
    var settings = WorkflowSettings.default
    let profile = AgentProfile(id: UUID(), kind: .claudeCode, name: "Reviewer")
    settings.remember(
      WorkflowBindingMemory(
        scope: .user, workflowID: "review-loop", role: "reviewer",
        requirementsDigest: WorkflowAdmission.requirementsDigest(for: originalRole), profileID: profile.id))
    // The file now asks for a different agent — the digest no longer matches,
    // so admission would not pick up this memory either.
    let changedRole = WorkflowRole(name: "reviewer", source: .launch, agents: [.codex])
    let entry = Self.entry(id: "review-loop", scope: .user, roles: [changedRole])
    let agents = AgentSettings(profiles: [profile])
    let bindings = WorkflowsSettingsLogic.roleBindings(for: entry, workflows: settings, agents: agents)
    #expect(bindings.first?.profileName == nil)
  }

  // MARK: - Eligible repository projects

  @Test
  func eligibleRepositoryProjectsExcludesNonGitServerAndWorkspaceProjects() {
    let gitProject = Project(name: "repo", rootPath: "/tmp/repo", gitRoot: "/tmp/repo")
    let dirProject = Project(name: "dir", rootPath: "/tmp/dir")
    let serverProject = Project(
      name: "srv", rootPath: "/srv/repo", gitRoot: "/srv/repo", remoteHost: RemoteHost(alias: "box"))
    let workspaceProject = Project(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let eligible = WorkflowsSettingsLogic.eligibleRepositoryProjects([
      gitProject, dirProject, serverProject, workspaceProject,
    ])
    #expect(eligible.map(\.name) == ["repo"])
  }

  @Test
  func eligibleRepositoryProjectsExcludesAnArchivedMainCheckout() {
    let archivedMain = Worktree(name: "repo", path: "/tmp/repo", archived: true)
    let project = Project(name: "repo", rootPath: "/tmp/repo", gitRoot: "/tmp/repo", worktrees: [archivedMain])
    #expect(WorkflowsSettingsLogic.eligibleRepositoryProjects([project]).isEmpty)
  }

  @Test
  func eligibleRepositoryProjectsSortByName() {
    let beta = Project(name: "beta", rootPath: "/tmp/beta", gitRoot: "/tmp/beta")
    let alpha = Project(name: "alpha", rootPath: "/tmp/alpha", gitRoot: "/tmp/alpha")
    let eligible = WorkflowsSettingsLogic.eligibleRepositoryProjects([beta, alpha])
    #expect(eligible.map(\.name) == ["alpha", "beta"])
  }

  // MARK: - Repository groups

  @Test
  func repositoryGroupsSkipProjectsWithAnEmptyOrMissingScan() {
    let withFiles = Project(name: "has-files", rootPath: "/tmp/has-files", gitRoot: "/tmp/has-files")
    let emptyDirectory = Project(name: "empty-dir", rootPath: "/tmp/empty-dir", gitRoot: "/tmp/empty-dir")
    let noDirectory = Project(name: "no-dir", rootPath: "/tmp/no-dir", gitRoot: "/tmp/no-dir")
    let entry = Self.entry(id: "review-loop", scope: .repo)
    let groups = WorkflowsSettingsLogic.repositoryGroups(
      eligibleProjects: [withFiles, emptyDirectory, noDirectory],
      scanned: [withFiles.id: [entry], emptyDirectory.id: []])
    #expect(groups.map(\.projectID) == [withFiles.id])
    #expect(groups.first?.entries.map(\.id) == ["review-loop"])
  }

  @Test
  func repositoryGroupsSortEntriesByID() {
    let project = Project(name: "repo", rootPath: "/tmp/repo", gitRoot: "/tmp/repo")
    let second = Self.entry(id: "review-loop", scope: .repo)
    let first = Self.entry(id: "advisor", scope: .repo)
    let groups = WorkflowsSettingsLogic.repositoryGroups(
      eligibleProjects: [project], scanned: [project.id: [second, first]])
    #expect(groups.first?.entries.map(\.id) == ["advisor", "review-loop"])
  }
}
