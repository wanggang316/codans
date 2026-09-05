import Foundation
import Testing

@testable import CodansCore

/// The Launch Preview shown in Settings and the string typed into the pane
/// come from the same renderer, so these assertions pin both at once.
struct AgentLaunchCommandTests {
  private static let configRoot = URL(fileURLWithPath: "/tmp/codans-tests", isDirectory: true)

  private static func render(_ profile: AgentProfile) -> String {
    AgentLaunchCommand.render(profile: profile, configDirectory: configRoot)
  }

  @Test
  func defaultProfileRendersBareExecutable() {
    #expect(Self.render(AgentProfile(kind: .codex)) == "codex")
    #expect(Self.render(AgentProfile(kind: .claudeCode)) == "claude")
    #expect(Self.render(AgentProfile(kind: .cursorAgent)) == "cursor-agent")
  }

  @Test
  func modelAndReasoningEffortRenderThroughTheDescriptorFlagStyle() {
    let profile = AgentProfile(
      kind: .codex,
      modelID: "gpt-5.1",
      reasoningEffortID: "high"
    )
    #expect(Self.render(profile) == "codex --model 'gpt-5.1' -c 'model_reasoning_effort=high'")
  }

  @Test
  func executionModeContributesItsOwnLiteralArguments() {
    var profile = AgentProfile(kind: .claudeCode, executionModeID: "plan")
    #expect(Self.render(profile) == "claude --permission-mode plan")

    profile.executionModeID = "standard"
    #expect(Self.render(profile) == "claude")
  }

  @Test
  func optionIdsTheAgentNoLongerOffersAreDropped() {
    // Swapping the agent (or hand-editing settings.json) can leave an id
    // behind that this CLI never understood; it must not reach the command.
    let profile = AgentProfile(
      kind: .amp,
      modelID: "gpt-5.1",
      reasoningEffortID: "high",
      executionModeID: "full-auto"
    )
    #expect(Self.render(profile) == "amp")
  }

  @Test
  func environmentVariablesRideAnEnvPrefixSortedByKey() {
    let profile = AgentProfile(
      kind: .codex,
      envVars: ["ZULU": "1", "ALPHA": "two words"]
    )
    #expect(Self.render(profile) == "env ALPHA='two words' ZULU='1' codex")
  }

  @Test
  func dedicatedHomeIsAppendedLastSoItWinsOverAHandSetHome() {
    let profile = AgentProfile(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!,
      kind: .codex,
      envVars: ["HOME": "/somewhere/else"],
      usesDedicatedHome: true
    )
    let expectedHome = Self.configRoot
      .appendingPathComponent("agent-homes", isDirectory: true)
      .appendingPathComponent("00000000-0000-0000-0000-0000000000AB", isDirectory: true)
      .path(percentEncoded: false)
    #expect(
      Self.render(profile)
        == "env HOME='/somewhere/else' HOME='\(expectedHome)' codex"
    )
  }

  @Test
  func singleQuotesInValuesAreEscaped() {
    let profile = AgentProfile(kind: .codex, envVars: ["TOKEN": "it's"])
    #expect(Self.render(profile) == #"env TOKEN='it'\''s' codex"#)
  }

  @Test
  func extraArgumentsAreAppendedVerbatimAfterGeneratedFlags() {
    let profile = AgentProfile(
      kind: .codex,
      executionModeID: "full-auto",
      extraArguments: "  --search --cd \"$PWD\"  "
    )
    #expect(Self.render(profile) == #"codex --full-auto --search --cd "$PWD""#)
  }

  @Test
  func everyDescriptorDeclaresAStandardExecutionModeFirstOrNoneAtAll() {
    for descriptor in AgentCatalog.all {
      guard let first = descriptor.executionModes.first else { continue }
      let isFlagless = first.arguments.isEmpty
      #expect(
        isFlagless,
        "\(descriptor.kind.rawValue) must lead with a no-flag Standard mode"
      )
    }
  }
}

/// A handoff seeds the receiver with a kickoff prompt; the descriptor decides
/// how (and whether) the CLI can take one.
struct AgentLaunchCommandPromptTests {
  private static let configRoot = URL(fileURLWithPath: "/tmp/codans-tests", isDirectory: true)

  @Test
  func promptTrailsEveryOtherArgumentInTheAgentsOwnSpelling() {
    let claude = AgentProfile(kind: .claudeCode, executionModeID: "plan", extraArguments: "--verbose")
    #expect(
      AgentLaunchCommand.render(profile: claude, prompt: "take over", configDirectory: Self.configRoot)
        == "claude --permission-mode plan --verbose 'take over'")

    let gemini = AgentProfile(kind: .gemini, modelID: "gemini-2.5-pro")
    #expect(
      AgentLaunchCommand.render(profile: gemini, prompt: "it's go", configDirectory: Self.configRoot)
        == "gemini --model 'gemini-2.5-pro' -i 'it'\\''s go'")
  }

  @Test
  func agentsWithoutAPromptStyleIgnoreThePrompt() {
    let amp = AgentProfile(kind: .amp)
    #expect(AgentLaunchCommand.render(profile: amp, prompt: "x", configDirectory: Self.configRoot) == "amp")
    #expect(!AgentCatalog.descriptor(for: .amp).supportsInitialPrompt)
    #expect(AgentCatalog.handoffReceivers == [.claudeCode, .codex, .gemini, .cursorAgent, .omp])
  }

  @Test
  func emptyPromptRendersNothing() {
    let codex = AgentProfile(kind: .codex)
    #expect(AgentLaunchCommand.render(profile: codex, prompt: "", configDirectory: Self.configRoot) == "codex")
  }
}

struct AgentKindTokenTests {
  @Test
  func acceptsRawValueExecutableAndDisplayName() {
    #expect(AgentKind(token: "claude-code") == .claudeCode)
    #expect(AgentKind(token: "claude") == .claudeCode)
    #expect(AgentKind(token: " Claude Code ") == .claudeCode)
    #expect(AgentKind(token: "CODEX") == .codex)
    #expect(AgentKind(token: "omp") == .omp)
    #expect(AgentKind(token: "Grok Build") == .grok)
    #expect(AgentKind(token: "") == nil)
    #expect(AgentKind(token: "aider") == nil)
  }
}
