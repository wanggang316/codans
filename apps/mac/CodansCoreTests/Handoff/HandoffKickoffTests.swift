import Foundation
import Testing

@testable import CodansCore

struct HandoffKickoffTests {
  private static let requestID = UUID(uuidString: "0B6D6A2E-5B3C-4D1F-9E1A-000000000001")!

  @Test
  func sourceInstructionIsOneLineAndCarriesTheRequestID() {
    let text = HandoffKickoff.sourceInstruction(for: .handOff(to: .codex), requestID: Self.requestID)
    #expect(!text.contains("\n"))
    #expect(text.hasPrefix("[codans] Please hand this task off to Codex: run "))
    #expect(text.contains("`CODANS_HANDOFF_REQUEST_ID=\(Self.requestID.uuidString) codans handoff to codex --brief -`"))
    #expect(text.contains("## Suggested Prompt For Next Agent"))

    let checkpoint = HandoffKickoff.sourceInstruction(for: .checkpoint, requestID: Self.requestID)
    #expect(checkpoint.contains("codans handoff save --brief -`"))
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
  func briefRequiredMessageEmbedsACopyPasteableHeredoc() {
    let message = HandoffKickoff.briefRequiredMessage(command: "codans handoff to codex --brief -")
    #expect(message.contains("codans handoff to codex --brief - <<'EOF'"))
    #expect(message.contains("  ## Next Steps\n  …"))
    #expect(message.hasSuffix("context-only handoff."))
  }
}
