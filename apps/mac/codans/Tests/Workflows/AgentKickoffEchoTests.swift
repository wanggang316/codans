import CodansCore
import Foundation
import Testing

@testable import Codans

struct AgentKickoffEchoTests {
  private let prompt = "Execute this workflow request in your existing session.\nRun ID: example"
  private let folded = """
    ╭── 📄 #1 ───╮
    │Execute thi…│
    │Run ID: exa…│
    ╰ +27 lines ─╯
    ╭── π > ◒ GLM-5.3 ──╮
    ╰─ 📄 #1             ─╯
    """

  @Test func recognizesNewOmpAttachmentWithTruncatedPromptPreview() {
    #expect(AgentKickoffEcho.containsPaste(kind: .omp, prompt: prompt, before: "╰─ ─╯", after: folded))
  }

  @Test func rejectsExistingAttachmentAndUnrelatedOrInsufficientPreview() {
    #expect(!AgentKickoffEcho.containsPaste(kind: .omp, prompt: prompt, before: folded, after: folded))
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .omp, prompt: prompt, before: "",
        after: folded.replacingOccurrences(of: "Execute thi", with: "Other text")))
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .omp, prompt: prompt, before: "", after: folded.replacingOccurrences(of: "Execute thi", with: "Ex")))
    #expect(!AgentKickoffEcho.containsPaste(kind: .claudeCode, prompt: prompt, before: "", after: folded))
  }

  @Test func rejectsNewUnrelatedCardBesideOldMatchingCard() {
    let unrelated = folded.replacingOccurrences(of: "#1", with: "#2")
      .replacingOccurrences(of: "Execute thi", with: "Unrelated x")
    #expect(
      !AgentKickoffEcho.containsPaste(kind: .omp, prompt: prompt, before: folded, after: folded + "\n" + unrelated))
  }

  @Test func detectsOnlyComposerAttachmentsAsPendingInput() {
    #expect(AgentKickoffEcho.hasPendingOmpAttachment(folded))
    #expect(!AgentKickoffEcho.hasPendingOmpAttachment("╭── π > GLM-5.3 ──╮\n╰─ ─╯"))
    let historyOnly = "╭── 📄 #1 ───╮\n│Execute thi…│\n╰ +27 lines ─╯\n╭── π > GLM-5.3 ──╮\n╰─ ─╯"
    #expect(!AgentKickoffEcho.hasPendingOmpAttachment(historyOnly))
  }

  @Test func preservesVisiblePromptAndExistingPasteChipSupport() {
    #expect(AgentKickoffEcho.containsPaste(kind: .claudeCode, prompt: prompt, before: "", after: prompt))
    #expect(AgentKickoffEcho.containsPaste(kind: .opencode, prompt: prompt, before: "", after: "[Pasted ~30 lines]"))
    #expect(!AgentKickoffEcho.containsPaste(kind: .omp, prompt: "", before: "", after: folded))
  }
}
