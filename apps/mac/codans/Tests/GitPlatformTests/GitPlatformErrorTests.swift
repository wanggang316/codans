import Foundation
import Testing

@testable import Codans

struct GitPlatformErrorTests {
  @Test
  func notInstalledMessageCarriesBrewCommand() {
    #expect(GitPlatformError.cliNotInstalled(.github).userFacingMessage.contains("brew install gh"))
  }

  @Test
  func notAuthenticatedWithHostMentionsHost() {
    let msg = GitPlatformError.notAuthenticated(.github, host: "github.com").userFacingMessage
    #expect(msg.contains("github.com"))
    #expect(msg.contains("gh auth login"))
  }

  @Test
  func notAuthenticatedWithoutHostStillMentionsLogin() {
    let msg = GitPlatformError.notAuthenticated(.github, host: nil).userFacingMessage
    #expect(msg.contains("gh auth login"))
  }

  @Test
  func networkCaseSurfacesUnderlyingText() {
    let msg = GitPlatformError.network("connection refused").userFacingMessage
    #expect(msg.contains("connection refused"))
  }

  @Test
  func rateLimitedMessageIsShort() {
    let msg = GitPlatformError.rateLimited(retryAfter: nil).userFacingMessage
    #expect(msg.contains("rate limit"))
  }

  @Test
  func headMovedAsksForAReview() {
    #expect(
      GitPlatformError.headMoved.userFacingMessage == "The branch has new commits. Review them, then merge again.")
  }

  @Test
  func otherCaseEmbedsDetail() {
    let msg = GitPlatformError.other("unexpected json at key 'foo'").userFacingMessage
    #expect(msg.contains("unexpected json at key 'foo'"))
  }

  @Test
  func equalityHonorsAssociatedValues() {
    #expect(GitPlatformError.cliNotInstalled(.github) == GitPlatformError.cliNotInstalled(.github))
    #expect(GitPlatformError.other("a") == GitPlatformError.other("a"))
    #expect(GitPlatformError.other("a") != GitPlatformError.other("b"))
    #expect(GitPlatformError.notAuthenticated(.github, host: "a") != GitPlatformError.notAuthenticated(.github, host: "b"))
    #expect(GitPlatformError.rateLimited(retryAfter: nil) != GitPlatformError.rateLimited(retryAfter: .seconds(30)))
  }
}
