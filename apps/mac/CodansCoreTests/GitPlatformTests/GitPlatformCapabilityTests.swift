import Testing

@testable import CodansCore

struct GitPlatformCapabilityTests {
  @Test
  func everyKindListsEveryCapabilityOnce() {
    let expected: [GitPlatformCapability.Key] = [
      .pullRequestBadges, .ciStatus, .merge(.mergeCommit), .merge(.squash), .merge(.rebase),
      .markReady, .rerunFailedChecks, .reviewStatus,
    ]
    for kind in GitPlatformKind.allCases {
      #expect(kind.capabilities.map(\.id) == expected)
    }
  }

  @Test
  func gitHubSupportsEveryCapability() {
    #expect(GitPlatformKind.github.capabilities.allSatisfy { $0.isSupported })
    #expect(GitPlatformKind.github.supportedMergeStrategies == MergeStrategy.allCases)
  }

  /// GitLab merges with the project's merge method, so codans cannot ask for a rebase.
  @Test
  func gitLabRebaseIsUnsupportedWithItsReason() {
    let rebase = GitPlatformKind.gitlab.capability(.merge(.rebase))
    #expect(rebase?.isSupported == false)
    #expect(rebase?.unsupportedReason == "The project's merge method applies")
    #expect(GitPlatformKind.gitlab.supportedMergeStrategies == [.mergeCommit, .squash])
  }

  /// Titles use the terms of each Git Platform.
  @Test
  func titlesUseTheTermsOfTheGitPlatform() {
    #expect(GitPlatformKind.github.capability(.pullRequestBadges)?.title == "Pull Request badges")
    #expect(GitPlatformKind.gitlab.capability(.pullRequestBadges)?.title == "Merge Request badges")
    #expect(GitPlatformKind.github.capability(.ciStatus)?.title == "Check status")
    #expect(GitPlatformKind.gitlab.capability(.ciStatus)?.title == "Pipeline status")
    #expect(GitPlatformKind.gitlab.capability(.rerunFailedChecks)?.title == "Retry failed pipeline jobs")
  }
}
