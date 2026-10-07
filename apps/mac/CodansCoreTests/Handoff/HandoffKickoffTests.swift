import Foundation
import Testing

@testable import CodansCore

struct HandoffKickoffTests {
  private static let requestID = UUID(uuidString: "0B6D6A2E-5B3C-4D1F-9E1A-000000000001")!

  private static let paneID = PaneID()

  @Test
  func sourceInstructionIsOneLineAndCarriesTheRequestID() {
    // Pass the invocation explicitly: the default follows the build channel
    // (`codans-dev` in Debug), which is not what this test is about.
    let text = HandoffKickoff.sourceInstruction(
      for: .handOff(to: .codex), requestID: Self.requestID, sourcePaneID: Self.paneID, cli: "codans")
    #expect(!text.contains("\n"))
    #expect(text.hasPrefix("[codans] Please hand this task off to Codex: run "))
    #expect(
      text.contains(
        "`CODANS_HANDOFF_REQUEST_ID=\(Self.requestID.uuidString) codans handoff to codex --pane \(Self.paneID.description) --brief -`"
      ))
    #expect(text.contains("## Suggested Prompt For Next Agent"))

    let checkpoint = HandoffKickoff.sourceInstruction(
      for: .checkpoint, requestID: Self.requestID, sourcePaneID: Self.paneID, cli: "codans")
    #expect(checkpoint.contains("codans handoff save --pane \(Self.paneID.description) --brief -`"))
  }

  @Test
  func sourceInstructionCarriesASplitPlacementAsCLIFlags() {
    let split = HandoffKickoff.sourceInstruction(
      for: .handOff(to: .codex), requestID: Self.requestID, sourcePaneID: Self.paneID, cli: "codans", placement: .split(.down))
    #expect(split.contains(" codans handoff to codex --pane \(Self.paneID.description) --split down --brief -`"))
    // A checkpoint has no receiver to place.
    let checkpoint = HandoffKickoff.sourceInstruction(
      for: .checkpoint, requestID: Self.requestID, sourcePaneID: Self.paneID, cli: "codans", placement: .split(.down))
    #expect(!checkpoint.contains("--split"))
  }

  @Test
  func receiverPromptPointsAtTheArtifactPaths() {
    let withBriefing = HandoffKickoff.receiverPrompt(hasBriefing: true)
    #expect(withBriefing.contains(".codans/handoff/current.md"))
    #expect(withBriefing.contains("continue from Next Steps"))
    let without = HandoffKickoff.receiverPrompt(hasBriefing: false)
    #expect(without.contains("There is no briefing"))
    #expect(!without.contains("current.md"))
    #expect(without.contains(".codans/handoff/context.md"))
  }

  @Test
  func commandOmitsTheRequestIDOnlyForAnOrdinaryCLICall() {
    let ordinary = HandoffKickoff.command(
      for: .checkpoint, requestID: nil, sourcePaneID: Self.paneID, cli: "codans")
    #expect(ordinary == "codans handoff save --pane \(Self.paneID) --brief -")
    let bound = HandoffKickoff.command(
      for: .handOff(to: .codex), requestID: Self.requestID, sourcePaneID: Self.paneID, cli: "codans",
      placement: .split(.down))
    #expect(
      bound
        == "CODANS_HANDOFF_REQUEST_ID=\(Self.requestID.uuidString) codans handoff to codex "
        + "--pane \(Self.paneID) --split down --brief -")
  }

  @Test
  func briefRequiredMessageEmbedsACopyPasteableHeredoc() {
    let message = HandoffKickoff.briefRequiredMessage(command: "codans handoff to codex --brief -")
    #expect(message.contains("codans handoff to codex --brief - <<'EOF'"))
    #expect(message.contains("  ## Next Steps\n  …"))
    #expect(message.hasSuffix("context-only handoff."))
  }

  @Test
  func sourceInstructionNamesTheCallersOwnCLI() {
    // The whole point of threading the invocation: a Debug app writing plain
    // `codans` would be answered by the installed Release app.
    let text = HandoffKickoff.sourceInstruction(
      for: .handOff(to: .codex), requestID: Self.requestID, sourcePaneID: Self.paneID, cli: "/opt/build/codans")
    #expect(text.contains("/opt/build/codans handoff to codex --pane \(Self.paneID.description) --brief -"))
    #expect(!text.contains(" codans handoff"))
  }
}
