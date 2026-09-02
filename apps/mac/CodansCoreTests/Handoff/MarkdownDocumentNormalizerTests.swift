import Foundation
import Testing

@testable import CodansCore

/// The normalizer only removes chat wrapping. Every assertion here pins that
/// the document body survives byte-for-byte and that structure questions
/// ignore what sits inside code fences.
struct MarkdownDocumentNormalizerTests {
  @Test
  func stripsOpeningAndClosingFence() {
    let wrapped = """
      ```markdown
      # Handoff
      ## Objective
      Ship it.
      ```
      """
    #expect(MarkdownDocumentNormalizer.normalized(wrapped) == "# Handoff\n## Objective\nShip it.")
  }

  @Test
  func dropsChatterBeforeTheFirstHeadingAndAfterTheClosingFence() {
    let reply = """
      Sure — here is the briefing:

      ```
      # Handoff
      ## Objective
      Do the thing.
      ```

      Let me know if you need anything else!
      """
    #expect(MarkdownDocumentNormalizer.normalized(reply) == "# Handoff\n## Objective\nDo the thing.")
  }

  @Test
  func keepsBareCodeBlocksInsideTheBody() {
    let doc = """
      # Handoff
      ## Current State
      Run this:
      ```
      make build
      ```
      ## Next Steps
      1. Ship.
      """
    #expect(MarkdownDocumentNormalizer.normalized(doc) == doc)
  }

  @Test
  func wrapperFenceSurvivesAnInnerInfoStringBlock() {
    let wrapped = """
      ```markdown
      # Handoff
      ## Current State
      ```swift
      let x = 1
      ```
      ## Next Steps
      - go
      ```
      """
    let expected = "# Handoff\n## Current State\n```swift\nlet x = 1\n```\n## Next Steps\n- go"
    #expect(MarkdownDocumentNormalizer.normalized(wrapped) == expected)
  }

  @Test
  func headingsInsideFencesAreNotStructure() {
    let doc = """
      # Handoff
      ```
      ## Objective
      ```
      ## Next Steps
      """
    #expect(MarkdownDocumentNormalizer.headings(outsideFences: doc) == ["# Handoff", "## Next Steps"])
    #expect(MarkdownDocumentNormalizer.missingSections(["## Objective"], in: doc) == ["## Objective"])
  }

  @Test
  func sectionMatchingIgnoresLevelCaseAndTrailingText() {
    let doc = "# handoff\n### OBJECTIVE\n## Next Steps (3)\n"
    #expect(MarkdownDocumentNormalizer.hasSections(["## Objective", "## Next Steps"], in: doc))
    #expect(!MarkdownDocumentNormalizer.hasSections(["## Next Stepsish"], in: doc))
  }

  @Test
  func indentedHashesAreCodeNotHeadings() {
    #expect(MarkdownDocumentNormalizer.atxHeading("    ## code") == nil)
    #expect(MarkdownDocumentNormalizer.atxHeading("   ## ok") == "## ok")
    #expect(MarkdownDocumentNormalizer.atxHeading("#hashtag") == nil)
    #expect(MarkdownDocumentNormalizer.atxHeading("#######") == nil)
  }

  @Test
  func textWithoutAnyHeadingIsReturnedUntouched() {
    #expect(MarkdownDocumentNormalizer.normalized("just prose\nmore prose") == "just prose\nmore prose")
    #expect(MarkdownDocumentNormalizer.normalized("   \n") == "")
  }
}
