import Foundation
import Testing

@testable import CodansCore

/// Skills of an agent that runs now: its argv, read from the kernel,
/// decides which launch flags it resolves with (ADR 0010).
struct SkillLaunchTests {
  private let home = URL(fileURLWithPath: "/tmp/skill-launch/home", isDirectory: true)
  private let state = URL(fileURLWithPath: "/tmp/skill-launch/state", isDirectory: true)

  // MARK: - Running agent

  @Test
  func runningAgentUsesTheUserRootsAndItsExactArguments() {
    let launch = SkillLaunch(kind: .claudeCode, arguments: ["--settings", "/a b/s.json"])
    #expect(launch.profile.envVars.isEmpty)
    #expect(!launch.profile.usesDedicatedHome)
    #expect(launch.arguments == ["--settings", "/a b/s.json"])
    // Two reads of one agent compare equal.
    #expect(launch == SkillLaunch(kind: .claudeCode, arguments: ["--settings", "/a b/s.json"]))
  }

  @Test
  func quotedTildeMakesTheArgumentsUnreadable() {
    #expect(SkillLaunch(kind: .claudeCode, arguments: ["--settings", "~/s.json"]).arguments == nil)
  }

  @Test
  func profilesThatMoveTheHomeOrConfigRoot() {
    #expect(!SkillLocationResolver.movesSkillRoots(AgentProfile(kind: .claudeCode)))
    #expect(
      !SkillLocationResolver.movesSkillRoots(AgentProfile(kind: .claudeCode, envVars: ["CODEX_HOME": "/x"])))
    #expect(SkillLocationResolver.movesSkillRoots(AgentProfile(kind: .claudeCode, usesDedicatedHome: true)))
    #expect(SkillLocationResolver.movesSkillRoots(AgentProfile(kind: .codex, envVars: ["HOME": "/x"])))
    #expect(
      SkillLocationResolver.movesSkillRoots(AgentProfile(kind: .claudeCode, envVars: ["CLAUDE_CONFIG_DIR": "/x"])))
    #expect(SkillLocationResolver.movesSkillRoots(AgentProfile(kind: .codex, envVars: ["CODEX_HOME": "/x"])))
  }

  /// The prompt a launch passes is one exact word, so it does not hide the
  /// flags the way a quoted shell fragment does.
  @Test
  func exactArgumentsWithAPromptStayReadable() {
    let prompted = SkillLaunch(kind: .pi, arguments: ["fix the bug"])
    #expect(
      !SkillLocationResolver.directories(
        for: prompted, projectStart: nil, userHome: home, stateDirectory: state
      ).isEmpty)
    let noSkills = SkillLaunch(kind: .pi, arguments: ["--no-skills", "fix the bug"])
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
