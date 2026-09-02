import Foundation
import Testing

@testable import CodansCore

struct HandoffBriefingTests {
  private static let complete = """
    # Handoff
    ## Objective
    Finish the agents pane.
    ## Current State
    Editor works.
    ## Next Steps
    1. Wire the toolbar.
    """

  @Test
  func completeBriefingIsInstalledWithATrailingNewline() {
    #expect(HandoffBriefing.validated(Self.complete) == Self.complete + "\n")
  }

  @Test
  func fencedReplyIsUnwrappedBeforeValidation() {
    let wrapped = "Here you go:\n```markdown\n" + Self.complete + "\n```\nDone."
    #expect(HandoffBriefing.validated(wrapped) == Self.complete + "\n")
  }

  @Test
  func missingRequiredSectionRejects() {
    let partial = "# Handoff\n## Objective\nx\n## Next Steps\ny\n"
    #expect(HandoffBriefing.validated(partial) == nil)
    #expect(HandoffBriefing.validated("") == nil)
    #expect(HandoffBriefing.validated("no headings here") == nil)
  }

  @Test
  func preparedBriefingThrowsOnInvalidInlineTextAndAcceptsContextOnly() throws {
    #expect(throws: HandoffError.invalidBriefing) {
      try HandoffPreparedBriefing(source: .inline("nope"))
    }
    let prepared = try HandoffPreparedBriefing(source: .inline(Self.complete))
    #expect(prepared.outcome == .inline)
    #expect(prepared.artifact == Self.complete + "\n")

    let contextOnly = try HandoffPreparedBriefing(source: .none)
    #expect(contextOnly == .contextOnly)
    #expect(!contextOnly.outcome.wroteBriefing)
  }
}
