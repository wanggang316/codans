import Foundation
import Testing

@testable import Codans

struct CodeHostErrorTests {
  @Test
  func notInstalledMessageCarriesBrewCommand() {
    #expect(CodeHostError.cliNotInstalled(.github).userFacingMessage.contains("brew install gh"))
  }

  @Test
  func notAuthenticatedWithHostMentionsHost() {
    let msg = CodeHostError.notAuthenticated(.github, host: "github.com").userFacingMessage
    #expect(msg.contains("github.com"))
    #expect(msg.contains("gh auth login"))
  }

  @Test
  func notAuthenticatedWithoutHostStillMentionsLogin() {
    let msg = CodeHostError.notAuthenticated(.github, host: nil).userFacingMessage
    #expect(msg.contains("gh auth login"))
  }

  @Test
  func networkCaseSurfacesUnderlyingText() {
    let msg = CodeHostError.network("connection refused").userFacingMessage
    #expect(msg.contains("connection refused"))
  }

  @Test
  func rateLimitedMessageIsShort() {
    let msg = CodeHostError.rateLimited(retryAfter: nil).userFacingMessage
    #expect(msg.contains("rate limit"))
  }

  @Test
  func otherCaseEmbedsDetail() {
    let msg = CodeHostError.other("unexpected json at key 'foo'").userFacingMessage
    #expect(msg.contains("unexpected json at key 'foo'"))
  }

  @Test
  func equalityHonorsAssociatedValues() {
    #expect(CodeHostError.cliNotInstalled(.github) == CodeHostError.cliNotInstalled(.github))
    #expect(CodeHostError.other("a") == CodeHostError.other("a"))
    #expect(CodeHostError.other("a") != CodeHostError.other("b"))
    #expect(CodeHostError.notAuthenticated(.github, host: "a") != CodeHostError.notAuthenticated(.github, host: "b"))
    #expect(CodeHostError.rateLimited(retryAfter: nil) != CodeHostError.rateLimited(retryAfter: .seconds(30)))
  }
}
