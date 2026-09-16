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

  private func piScreen(_ input: String, history: String = "") -> String {
    "\(history)\n────────────────────\n\(input)\n────────────────────\n/tmp/test\n0% context"
  }

  @Test func recognizesPiCollapsedLinesAndCharacters() {
    let multiline = Array(repeating: "Instruction", count: 61).joined(separator: "\n")
    #expect(
      AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: multiline, before: piScreen(""), after: piScreen("[paste #1 +61 lines]"))
    )
    #expect(
      AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: multiline, before: piScreen(""), after: piScreen("[paste #2 +61 lines]")))
    let unicode = String(repeating: "🚀", count: 501)
    #expect(
      AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: unicode, before: piScreen(""), after: piScreen("[paste #1 1002 chars]")))
    let tabs = String(repeating: "\t", count: 251)
    #expect(
      AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: tabs, before: piScreen(""), after: piScreen("[paste #1 1004 chars]")))
  }

  @Test func piPasteEvidenceExcludesHistoryAndExistingDrafts() {
    let multiline = Array(repeating: "Instruction", count: 61).joined(separator: "\n")
    let chip = "[paste #1 +61 lines]"
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: multiline, before: piScreen(""), after: piScreen("", history: chip)))
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: multiline, before: piScreen(chip), after: piScreen(chip)))
    #expect(
      AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: multiline, before: piScreen("", history: chip),
        after: piScreen(chip, history: chip)))
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .pi, prompt: multiline, before: piScreen(""), after: piScreen("[paste #1 +60 lines]"))
    )
    #expect(!AgentKickoffEcho.canAcceptPaste(kind: .pi, screen: piScreen("Unsent draft")))
    #expect(!AgentKickoffEcho.canAcceptPaste(kind: .pi, screen: "Loading Pi..."))
    #expect(AgentKickoffEcho.canAcceptPaste(kind: .pi, screen: piScreen("")))
  }

  @Test func recognizesNewOmpAttachmentWithTruncatedPromptPreview() {
    #expect(
      AgentKickoffEcho.containsPaste(kind: .omp, prompt: prompt, before: "╰─ ─╯", after: folded))
  }

  @Test func rejectsExistingAttachmentAndUnrelatedOrInsufficientPreview() {
    #expect(
      !AgentKickoffEcho.containsPaste(kind: .omp, prompt: prompt, before: folded, after: folded))
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .omp, prompt: prompt, before: "",
        after: folded.replacingOccurrences(of: "Execute thi", with: "Other text")))
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .omp, prompt: prompt, before: "",
        after: folded.replacingOccurrences(of: "Execute thi", with: "Ex")))
    #expect(
      !AgentKickoffEcho.containsPaste(kind: .claudeCode, prompt: prompt, before: "", after: folded))
  }

  @Test func rejectsNewUnrelatedCardBesideOldMatchingCard() {
    let unrelated = folded.replacingOccurrences(of: "#1", with: "#2")
      .replacingOccurrences(of: "Execute thi", with: "Unrelated x")
    #expect(
      !AgentKickoffEcho.containsPaste(
        kind: .omp, prompt: prompt, before: folded, after: folded + "\n" + unrelated))
  }

  @Test func detectsOnlyComposerAttachmentsAsPendingInput() {
    #expect(AgentKickoffEcho.hasPendingOmpAttachment(folded))
    #expect(!AgentKickoffEcho.hasPendingOmpAttachment("╭── π > GLM-5.3 ──╮\n╰─ ─╯"))
    let historyOnly = "╭── 📄 #1 ───╮\n│Execute thi…│\n╰ +27 lines ─╯\n╭── π > GLM-5.3 ──╮\n╰─ ─╯"
    #expect(!AgentKickoffEcho.hasPendingOmpAttachment(historyOnly))
  }

  @Test func preservesVisiblePromptAndExistingPasteChipSupport() {
    #expect(
      AgentKickoffEcho.containsPaste(kind: .claudeCode, prompt: prompt, before: "", after: prompt))
    #expect(
      AgentKickoffEcho.containsPaste(
        kind: .opencode, prompt: prompt, before: "", after: "[Pasted ~30 lines]"))
    #expect(!AgentKickoffEcho.containsPaste(kind: .omp, prompt: "", before: "", after: folded))
  }
}
