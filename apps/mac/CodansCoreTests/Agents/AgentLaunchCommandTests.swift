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
