import Foundation
import Testing

@testable import CodansCore

/// Skills of an agent that runs now: its argv and environment, read from
/// the kernel, decide what it resolves (ADR 0010).
struct SkillLaunchTests {
  private let home = URL(fileURLWithPath: "/tmp/skill-launch/home", isDirectory: true)
  private let state = URL(fileURLWithPath: "/tmp/skill-launch/state", isDirectory: true)

  private func paths(_ directories: [SkillDirectory]) -> [String] {
    directories.map { $0.url.path(percentEncoded: false) }
  }

  // MARK: - Running agent

  @Test
  func runningAgentKeepsHomeAndConfigRootOnly() throws {
    let launch = try #require(
      SkillLaunch(
        kind: .claudeCode, arguments: ["--model", "opus"],
        environment: [
          "HOME": "/srv/agent-home", "CLAUDE_CONFIG_DIR": "/srv/claude", "API_TOKEN": "secret",
          "CODEX_HOME": "/srv/codex",
        ]))
    #expect(launch.profile.envVars == ["HOME": "/srv/agent-home", "CLAUDE_CONFIG_DIR": "/srv/claude"])
    #expect(launch.arguments == ["--model", "opus"])
    // Two reads of one agent compare equal.
    #expect(
      launch
        == SkillLaunch(
          kind: .claudeCode, arguments: ["--model", "opus"],
          environment: ["HOME": "/srv/agent-home", "CLAUDE_CONFIG_DIR": "/srv/claude"]))
  }

  @Test
  func relativeHomeCannotBePlaced() {
    #expect(SkillLaunch(kind: .codex, arguments: [], environment: ["HOME": "home"]) == nil)
  }

  @Test
  func quotedTildeMakesTheArgumentsUnreadable() throws {
    let launch = try #require(
      SkillLaunch(kind: .claudeCode, arguments: ["--settings", "~/s.json"], environment: [:]))
    #expect(launch.arguments == nil)
  }

  @Test
  func runningAgentResolvesAgainstItsOwnHomeAndConfigRoot() throws {
    let launch = try #require(
      SkillLaunch(
        kind: .claudeCode, arguments: [],
        environment: ["HOME": "/srv/agent-home"]))
    #expect(
      paths(SkillLocationResolver.userDirectories(for: launch.profile, userHome: home, stateDirectory: state))
        == ["/srv/agent-home/.claude/skills/"])
    let moved = try #require(
      SkillLaunch(
        kind: .claudeCode, arguments: [],
        environment: ["HOME": "/srv/agent-home", "CLAUDE_CONFIG_DIR": "/srv/claude"]))
    #expect(
      paths(SkillLocationResolver.userDirectories(for: moved.profile, userHome: home, stateDirectory: state))
        == ["/srv/claude/skills/"])
  }

  /// The prompt a launch passes is one exact word, so it does not hide the
  /// flags the way a quoted shell fragment does.
  @Test
  func exactArgumentsWithAPromptStayReadable() throws {
    let prompted = try #require(
      SkillLaunch(kind: .pi, arguments: ["fix the bug"], environment: ["HOME": home.path]))
    #expect(
      !SkillLocationResolver.directories(
        for: prompted, projectStart: nil, userHome: home, stateDirectory: state
      ).isEmpty)
    let noSkills = try #require(
      SkillLaunch(kind: .pi, arguments: ["--no-skills", "fix the bug"], environment: ["HOME": home.path]))
    #expect(
      SkillLocationResolver.directories(
        for: noSkills, projectStart: nil, userHome: home, stateDirectory: state
      ).isEmpty)
    // The same words as a profile's shell fragment cannot be read.
    let profile = AgentProfile(kind: .pi, extraArguments: "'fix the bug'")
    #expect(
      SkillLocationResolver.directories(
        for: profile, projectStart: nil, userHome: home, stateDirectory: state
      ).isEmpty)
  }

  // MARK: - Agent process

  private static func process(
    pid: Int32, _ argv: [String]?, started: TimeInterval = 0
  ) -> ForegroundProcess {
    ForegroundProcess(
      pid: pid, parentPID: 1, processGroupID: 10, argv0: argv?.first ?? "",
      commandLine: argv?.joined(separator: " ") ?? "",
      startedAt: Date(timeIntervalSince1970: started), arguments: argv)
  }

  @Test
  func agentProcessGivesTheArgumentsAfterItsExecutable() throws {
    let job = ForegroundJob(
      processGroupID: 10,
      processes: [Self.process(pid: 11, ["/usr/local/bin/claude", "--settings", "/a b/s.json"])])
    let launch = try #require(AgentKindPatterns.agentLaunch(of: .claudeCode, in: job))
    #expect(launch.pid == 11)
    #expect(launch.arguments == ["--settings", "/a b/s.json"])
  }

  @Test
  func wrapperGivesTheArgumentsAfterTheAgentScript() throws {
    let job = ForegroundJob(
      processGroupID: 10,
      processes: [Self.process(pid: 11, ["node", "--no-warnings", "/opt/bin/codex", "-p", "work"])])
    let launch = try #require(AgentKindPatterns.agentLaunch(of: .codex, in: job))
    #expect(launch.arguments == ["-p", "work"])
  }

  @Test
  func agentProcessWinsOverItsWrapperAndTheFirstStartedWins() throws {
    let job = ForegroundJob(
      processGroupID: 10,
      processes: [
        Self.process(pid: 11, ["node", "/opt/bin/codex", "--wrapper"], started: 1),
        Self.process(pid: 14, ["codex", "--child"], started: 3),
        Self.process(pid: 12, ["codex", "--parent"], started: 2),
      ])
    let launch = try #require(AgentKindPatterns.agentLaunch(of: .codex, in: job))
    #expect(launch.pid == 12)
    #expect(launch.arguments == ["--parent"])
  }

  @Test
  func unreadableArgvOrAnotherAgentGivesNothing() {
    let unreadable = ForegroundJob(processGroupID: 10, processes: [Self.process(pid: 11, nil)])
    #expect(AgentKindPatterns.agentLaunch(of: .claudeCode, in: unreadable) == nil)
    let other = ForegroundJob(processGroupID: 10, processes: [Self.process(pid: 11, ["codex"])])
    #expect(AgentKindPatterns.agentLaunch(of: .claudeCode, in: other) == nil)
  }
}
