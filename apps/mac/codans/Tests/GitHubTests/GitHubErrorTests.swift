import Foundation
import Testing

@testable import Codans

struct GitHubErrorTests {
  @Test
  func notInstalledMessageCarriesBrewCommand() {
    #expect(GitHubError.notInstalled.userFacingMessage.contains("brew install gh"))
  }

  @Test
  func notAuthenticatedWithHostMentionsHost() {
    let msg = GitHubError.notAuthenticated(host: "github.com").userFacingMessage
    #expect(msg.contains("github.com"))
    #expect(msg.contains("gh auth login"))
  }

  @Test
  func notAuthenticatedWithoutHostStillMentionsLogin() {
    let msg = GitHubError.notAuthenticated(host: nil).userFacingMessage
    #expect(msg.contains("gh auth login"))
  }

  @Test
  func networkCaseSurfacesUnderlyingText() {
    let msg = GitHubError.network("connection refused").userFacingMessage
    #expect(msg.contains("connection refused"))
  }

  @Test
  func rateLimitedMessageIsShort() {
    let msg = GitHubError.rateLimited(retryAfter: nil).userFacingMessage
    #expect(msg.contains("rate limit"))
  }

  @Test
  func otherCaseEmbedsDetail() {
    let msg = GitHubError.other("unexpected json at key 'foo'").userFacingMessage
    #expect(msg.contains("unexpected json at key 'foo'"))
  }

  @Test
  func equalityHonorsAssociatedValues() {
    #expect(GitHubError.notInstalled == GitHubError.notInstalled)
    #expect(GitHubError.other("a") == GitHubError.other("a"))
    #expect(GitHubError.other("a") != GitHubError.other("b"))
    #expect(GitHubError.notAuthenticated(host: "a") != GitHubError.notAuthenticated(host: "b"))
    #expect(GitHubError.rateLimited(retryAfter: nil) != GitHubError.rateLimited(retryAfter: .seconds(30)))
  }
}
