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
  func everyAgentKindHasOneEntryAndOnlyProbedAgentsCallSkills() {
    let enabled: [AgentKind: SkillLocation] = [
      .claudeCode: .claudeCode, .codex: .codex, .pi: .pi,
    ]
    for kind in AgentKind.allCases {
      let location = AgentCatalog.descriptor(for: kind).skillLocation
      if let expected = enabled[kind] {
        #expect(location == expected, "\(kind)")
        #expect(location.supportsCompletion)
      } else {
        #expect(location == .none, "\(kind)")
        #expect(!location.supportsCompletion)
      }
    }
  }

  @Test
  func userDirectoriesSplitIntoTheConfigRootOneAndSharedOnes() {
    #expect(SkillLocation.claudeCode.configRootUserDirectory == ".claude/skills")
    #expect(SkillLocation.claudeCode.sharedUserDirectories.isEmpty)
    #expect(SkillLocation.codex.configRootUserDirectory == ".codex/skills")
    #expect(SkillLocation.codex.sharedUserDirectories == [".agents/skills"])
    #expect(SkillLocation.pi.configRootUserDirectory == ".pi/agent/skills")
    #expect(SkillLocation.pi.sharedUserDirectories == [".agents/skills"])
    #expect(SkillLocation.none.configRootUserDirectory == nil)
    let rootless = SkillLocation(userDirectories: [".gemini/skills"])
    #expect(rootless.configRootUserDirectory == nil)
    #expect(rootless.sharedUserDirectories == [".gemini/skills"])
  }

  @Test
  func probedAgentsUseTheirInvocationStyleAndPosition() {
    #expect(SkillLocation.claudeCode.invocationStyle == .slash)
    #expect(SkillLocation.claudeCode.invocationPosition == .anywhere)
    #expect(SkillLocation.claudeCode.precedence == [.user, .project, .plugin])
    #expect(SkillLocation.codex.invocationStyle == .dollar)
    #expect(SkillLocation.codex.invocationPosition == .anywhere)
    #expect(SkillLocation.pi.invocationStyle == .slashSkill)
    #expect(SkillLocation.pi.invocationPosition == .anywhere)
  }

  @Test
  func invocationStyleSpellsTheToken() {
    #expect(SkillInvocationStyle.slash.token(for: "review") == "/review")
    #expect(SkillInvocationStyle.slashSkill.token(for: "review") == "/skill:review")
    #expect(SkillInvocationStyle.dollar.token(for: "docs:pdf") == "$docs:pdf")
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
    #expect(Self.paths(AgentProfile(kind: .gemini)).isEmpty)
    #expect(Self.paths(AgentProfile(kind: .opencode)).isEmpty)
  }

  @Test
  func codexReadsTheSharedFolderAndItsHome() {
    #expect(Self.paths(AgentProfile(kind: .codex)) == ["/Users/me/.agents/skills", "/Users/me/.codex/skills"])
    let moved = AgentProfile(kind: .codex, envVars: ["CODEX_HOME": "/srv/codex"])
    #expect(Self.paths(moved) == ["/Users/me/.agents/skills", "/srv/codex/skills"])
  }

  @Test
  func piReadsItsAgentDirectoryAndTheSharedFolder() {
    #expect(Self.paths(AgentProfile(kind: .pi)) == ["/Users/me/.pi/agent/skills", "/Users/me/.agents/skills"])
    let moved = AgentProfile(kind: .pi, envVars: ["PI_CODING_AGENT_DIR": "~/pi-work"])
    #expect(Self.paths(moved) == ["/Users/me/pi-work/skills", "/Users/me/.agents/skills"])
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
  func remoteProjectStartsInAPathOnItsHost() {
    var remote = Self.gitProject
    remote.remoteHost = RemoteHost(alias: "devbox")
    let feature = SkillLocationResolver.projectStartDirectory(in: remote, branch: "feature")
    #expect(Self.path(feature) == "/code/repo-worktrees/feature")
    #expect(Self.path(SkillLocationResolver.projectStartDirectory(in: remote, branch: nil)) == "/code/repo")
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
      projectDirectories: [
        SkillProjectDirectory(".gemini/skills", search: .workingDirectoryOnly),
        SkillProjectDirectory(".agents/skills", search: .workingDirectoryOnly),
      ],
      invocationStyle: .slash)
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
    #expect(
      Self.projectPaths(AgentProfile(kind: .gemini), from: "/code/repo", repositoryRoots: ["/code/repo"]).isEmpty)
  }

  @Test
  func codexWalksTheSharedFolderUpToTheRepositoryRoot() {
    #expect(
      Self.projectPaths(AgentProfile(kind: .codex), from: "/code/repo/apps", repositoryRoots: ["/code/repo"]) == [
        "/code/repo/apps/.agents/skills",
        "/code/repo/.agents/skills",
      ])
  }

  @Test
  func piReadsItsOwnFolderInTheWorkingDirectoryOnly() {
    #expect(
      Self.projectPaths(AgentProfile(kind: .pi), from: "/code/repo/apps", repositoryRoots: ["/code/repo"]) == [
        "/code/repo/apps/.pi/skills",
        "/code/repo/apps/.agents/skills",
        "/code/repo/.agents/skills",
      ])
  }

  @Test
  func sharedFolderSkillGoesToEveryAgentThatReadsIt() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "shared-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
    let repo = root.appending(path: "repo", directoryHint: .isDirectory)
    let skill = repo.appending(path: ".agents/skills/shared/SKILL.md")
    try FileManager.default.createDirectory(
      at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "---\nname: shared\ndescription: Shared.\n---\n".write(to: skill, atomically: true, encoding: .utf8)
    // `--approve`: Pi reads project skills only in a trusted project.
    for profile in [AgentProfile(kind: .codex), AgentProfile(kind: .pi, extraArguments: "--approve")] {
      let kind = profile.kind
      let directories = SkillLocationResolver.directories(
        for: profile, projectStart: repo,
        userHome: root.appending(path: "home"), stateDirectory: root.appending(path: "state"),
        isRepositoryRoot: { Self.path($0) == Self.path(repo) })
      #expect(SkillScanner.scanSync(directories).map(\.name) == ["shared"], "\(kind)")
    }
    let claude = SkillLocationResolver.directories(
      for: AgentProfile(kind: .claudeCode), projectStart: repo,
      userHome: root.appending(path: "home"), stateDirectory: root.appending(path: "state"),
      isRepositoryRoot: { Self.path($0) == Self.path(repo) })
    #expect(SkillScanner.scanSync(claude).isEmpty)
  }

  @Test
  func projectFilePathsAreTheProjectSkillsAndPluginSettingsTheAgentReads() {
    #expect(
      SkillLocationResolver.projectFilePaths(for: AgentProfile(kind: .claudeCode))
        == [".claude/skills", ".claude/settings.json", ".claude/settings.local.json"])
    #expect(
      SkillLocationResolver.projectFilePaths(
        for: AgentProfile(kind: .claudeCode, extraArguments: "--settings conf/agent.json"))
        == [".claude/skills", ".claude/settings.json", ".claude/settings.local.json", "conf/agent.json"])
    #expect(
      SkillLocationResolver.projectFilePaths(
        for: AgentProfile(kind: .claudeCode, extraArguments: "--settings /etc/agent.json")).count == 3)
    // Outside the directory the agent starts in: not a project file.
    #expect(
      SkillLocationResolver.projectFilePaths(
        for: AgentProfile(kind: .claudeCode, extraArguments: "--settings ../agent.json")).count == 3)
    #expect(
      SkillLocationResolver.projectFilePaths(
        for: AgentProfile(kind: .claudeCode, extraArguments: "--settings ./conf/../agent.json")).last
        == "agent.json")
    #expect(
      SkillLocationResolver.projectFilePaths(for: AgentProfile(kind: .codex))
        == [".agents/skills", ".codex/config.toml"])
    #expect(SkillLocationResolver.projectFilePaths(for: AgentProfile(kind: .pi)) == [".pi/skills", ".agents/skills"])
    #expect(SkillLocationResolver.projectFilePaths(for: AgentProfile(kind: .gemini)).isEmpty)
  }
}
