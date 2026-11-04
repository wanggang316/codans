import CodansCore
import Testing

@testable import Codans

@MainActor
struct CodeHostLabelsTests {
  @Test
  func gitHubReferenceUsesHash() {
    #expect(CodeHostLabels.referencePrefix(.github) == "#")
    #expect(CodeHostLabels.reference(.github, number: 6) == "#6")
  }

  /// GitLab names a merge request by its `!iid` (ADR 0004 item 4).
  @Test
  func gitLabReferenceUsesBang() {
    #expect(CodeHostLabels.referencePrefix(.gitlab) == "!")
    #expect(CodeHostLabels.reference(.gitlab, number: 6) == "!6")
  }

  /// A Worktree whose Code Host is not resolved yet keeps the GitHub form.
  @Test
  func unknownCodeHostReferenceUsesHash() {
    #expect(CodeHostLabels.referencePrefix(nil) == "#")
    #expect(CodeHostLabels.reference(nil, number: 6) == "#6")
  }
}
