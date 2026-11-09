import CodansCore
import Testing

@testable import Codans

@MainActor
struct GitPlatformLabelsTests {
  @Test
  func gitHubReferenceUsesHash() {
    #expect(GitPlatformLabels.referencePrefix(.github) == "#")
    #expect(GitPlatformLabels.reference(.github, number: 6) == "#6")
  }

  /// GitLab names a merge request by its `!iid` (ADR 0004 item 4).
  @Test
  func gitLabReferenceUsesBang() {
    #expect(GitPlatformLabels.referencePrefix(.gitlab) == "!")
    #expect(GitPlatformLabels.reference(.gitlab, number: 6) == "!6")
  }

  /// A Worktree whose Git Platform is not resolved yet keeps the GitHub form.
  @Test
  func unknownGitPlatformReferenceUsesHash() {
    #expect(GitPlatformLabels.referencePrefix(nil) == "#")
    #expect(GitPlatformLabels.reference(nil, number: 6) == "#6")
  }
}
