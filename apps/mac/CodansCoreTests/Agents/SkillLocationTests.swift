import Foundation
import Testing

@testable import CodansCore

struct SkillLocationTests {
  private static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
  private static let stateRoot = URL(fileURLWithPath: "/tmp/codans-tests/state", isDirectory: true)

  private static func paths(_ profile: AgentProfile) -> [String] {
    SkillLocationResolver.userDirectories(for: profile, userHome: home, stateDirectory: stateRoot)
      .map { url in
        let path = url.url.path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
      }
  }

  @Test
  func everyAgentKindHasOneEntryAndOnlyClaudeCodeCallsSkills() {
    for kind in AgentKind.allCases {
      let location = AgentCatalog.descriptor(for: kind).skillLocation
      if kind == .claudeCode {
        #expect(location.userDirectories == [".claude/skills"])
        #expect(location.configRoot?.environmentVariable == "CLAUDE_CONFIG_DIR")
        #expect(location.projectDirectories == [".claude/skills"])
        #expect(location.projectSearch == .walkUpToRepositoryRoot)
        #expect(location.precedence == [.user, .project, .plugin])
        #expect(location.invocationStyle == .slash)
        #expect(location.invocationPosition == .anywhere)
      } else {
        #expect(location == .none, "\(kind)")
        #expect(!location.supportsCompletion)
      }
    }
  }

  @Test
  func invocationStyleSpellsTheToken() {
    #expect(SkillInvocationStyle.slash.token(for: "review") == "/review")
    #expect(SkillInvocationStyle.none.token(for: "review") == nil)
  }

  @Test
  func userDirectoryResolvesAgainstTheUserHome() {
    #expect(Self.paths(AgentProfile(kind: .claudeCode)) == ["/Users/me/.claude/skills"])
  }

  @Test
  func userDirectoryResolvesAgainstTheDedicatedHome() {
    let profile = AgentProfile(kind: .claudeCode, usesDedicatedHome: true)
    #expect(
      Self.paths(profile) == [
        "/tmp/codans-tests/state/agent-homes/\(profile.id.uuidString)/.claude/skills"
      ])
  }

  @Test
  func dedicatedHomeWinsOverAHomeVariable() {
    let profile = AgentProfile(
      kind: .claudeCode, envVars: ["HOME": "/opt/other"], usesDedicatedHome: true)
    #expect(Self.paths(profile).first?.hasPrefix("/tmp/codans-tests/state/agent-homes/") == true)
    let plain = AgentProfile(kind: .claudeCode, envVars: ["HOME": "/opt/other"])
    #expect(Self.paths(plain) == ["/opt/other/.claude/skills"])
  }

  @Test
  func configRootVariableReplacesTheDefaultRoot() {
    let profile = AgentProfile(kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": "/srv/claude-work"])
    #expect(Self.paths(profile) == ["/srv/claude-work/skills"])
  }

  @Test
  func configRootTildeExpandsAgainstTheEffectiveHome() {
    let profile = AgentProfile(
      kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": "~/alt"], usesDedicatedHome: true)
    #expect(
      Self.paths(profile) == [
        "/tmp/codans-tests/state/agent-homes/\(profile.id.uuidString)/alt/skills"
      ])
  }

  @Test
  func relativeConfigRootIsLeftOut() {
    let profile = AgentProfile(kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": "conf"])
    #expect(Self.paths(profile).isEmpty)
  }

  @Test
  func agentWithoutInvocationStyleResolvesNothing() {
    #expect(Self.paths(AgentProfile(kind: .codex)).isEmpty)
  }

  // MARK: - Project directories

  private static func path(_ url: URL?) -> String? {
    url.map { url in
      let path = url.path(percentEncoded: false)
      return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
  }

  private static func projectPaths(
    _ profile: AgentProfile = AgentProfile(kind: .claudeCode), from start: String,
    repositoryRoots: Set<String>
  ) -> [String] {
    SkillLocationResolver.projectDirectories(
      for: profile, startDirectory: URL(fileURLWithPath: start, isDirectory: true),
      isRepositoryRoot: { repositoryRoots.contains(path($0) ?? "") }
    ).map { $0.source == .project ? path($0.url) ?? "" : "not a project directory" }
  }

  private static let gitProject = Project(
    name: "repo", rootPath: "/code/repo", gitRoot: "/code/repo",
    worktrees: [
      Worktree(name: "repo", path: "/code/repo", branch: "main"),
      Worktree(name: "feature", path: "/code/repo-worktrees/feature", branch: "feature"),
      Worktree(name: "old", path: "/code/repo-worktrees/old", branch: "old", archived: true),
    ])

  @Test
  func existingWorktreeStartsInThatWorktree() {
    let start = SkillLocationResolver.projectStartDirectory(in: Self.gitProject, branch: "feature")
    #expect(Self.path(start) == "/code/repo-worktrees/feature")
  }

  @Test
  func newWorktreeStartsInTheMainCheckout() {
    #expect(
      Self.path(SkillLocationResolver.projectStartDirectory(in: Self.gitProject, branch: nil))
        == "/code/repo")
    // A branch that only an archived worktree, or no worktree, holds is
    // checked out into a new worktree.
    #expect(
      Self.path(SkillLocationResolver.projectStartDirectory(in: Self.gitProject, branch: "old"))
        == "/code/repo")
    #expect(
      Self.path(SkillLocationResolver.projectStartDirectory(in: Self.gitProject, branch: "other"))
        == "/code/repo")
  }

  @Test
  func onlyABranchWithoutALiveWorktreeCreatesOne() {
    #expect(SkillLocationResolver.createsWorktree(in: Self.gitProject, branch: nil))
    #expect(SkillLocationResolver.createsWorktree(in: Self.gitProject, branch: "old"))
    #expect(SkillLocationResolver.createsWorktree(in: Self.gitProject, branch: "other"))
    #expect(!SkillLocationResolver.createsWorktree(in: Self.gitProject, branch: "main"))
    let folder = Project(
      name: "notes", rootPath: "/code/notes", worktrees: [Worktree(name: "notes", path: "/code/notes")])
    #expect(!SkillLocationResolver.createsWorktree(in: folder, branch: nil))
  }

  @Test
  func folderProjectStartsInItsFolder() {
    let folder = Project(
      name: "notes", rootPath: "/code/notes", worktrees: [Worktree(name: "notes", path: "/code/notes")])
    #expect(Self.path(SkillLocationResolver.projectStartDirectory(in: folder, branch: nil)) == "/code/notes")
  }

  @Test
  func workspaceProjectStartsInItsWorkingDirectory() {
    let root = Worktree(name: "ws", path: "/code/ws")
    let member = Worktree(name: "api", path: "/code/ws/api", branch: "main")
    let workspace = Project(
      name: "ws", rootPath: "/code/ws", worktrees: [root, member], selectedWorktreeID: member.id,
      isWorkspace: true)
    #expect(
      Self.path(SkillLocationResolver.projectStartDirectory(in: workspace, branch: "main"))
        == "/code/ws/api")
    var unselected = workspace
    unselected.selectedWorktreeID = nil
    #expect(
      Self.path(SkillLocationResolver.projectStartDirectory(in: unselected, branch: nil)) == "/code/ws")
  }

  @Test
  func remoteProjectHasNoStartDirectory() {
    var remote = Self.gitProject
    remote.remoteHost = RemoteHost(alias: "devbox")
    #expect(SkillLocationResolver.projectStartDirectory(in: remote, branch: nil) == nil)
  }

  @Test
  func walkUpStopsAtTheRepositoryRoot() {
    #expect(
      Self.projectPaths(from: "/code/repo/apps/web", repositoryRoots: ["/code/repo", "/code"]) == [
        "/code/repo/apps/web/.claude/skills",
        "/code/repo/apps/.claude/skills",
        "/code/repo/.claude/skills",
      ])
    #expect(
      Self.projectPaths(from: "/code/repo", repositoryRoots: ["/code/repo"]) == [
        "/code/repo/.claude/skills"
      ])
  }

  @Test
  func walkUpWithoutARepositoryReadsTheStartDirectoryOnly() {
    #expect(
      Self.projectPaths(from: "/code/notes/sub", repositoryRoots: []) == [
        "/code/notes/sub/.claude/skills"
      ])
  }

  @Test
  func workingDirectoryOnlySearchDoesNotWalkUp() {
    let location = SkillLocation(
      projectDirectories: [".gemini/skills", ".agents/skills"],
      projectSearch: .workingDirectoryOnly, invocationStyle: .slash)
    let directories = SkillLocationResolver.projectDirectories(
      in: location, startDirectory: URL(fileURLWithPath: "/code/repo/apps", isDirectory: true),
      isRepositoryRoot: { Self.path($0) == "/code/repo" })
    #expect(
      directories.map { Self.path($0.url) } == [
        "/code/repo/apps/.gemini/skills", "/code/repo/apps/.agents/skills",
      ])
  }

  @Test
  func directoriesListProjectBeforeUser() {
    let directories = SkillLocationResolver.directories(
      for: AgentProfile(kind: .claudeCode),
      projectStart: URL(fileURLWithPath: "/code/repo", isDirectory: true),
      userHome: Self.home, stateDirectory: Self.stateRoot,
      isRepositoryRoot: { Self.path($0) == "/code/repo" })
    #expect(directories.map(\.source) == [.project, .user])
    #expect(directories.map { Self.path($0.url) } == ["/code/repo/.claude/skills", "/Users/me/.claude/skills"])
  }

  @Test
  func agentWithoutInvocationStyleHasNoProjectDirectories() {
    #expect(Self.projectPaths(AgentProfile(kind: .codex), from: "/code/repo", repositoryRoots: ["/code/repo"]).isEmpty)
  }
}
