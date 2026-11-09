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
}
