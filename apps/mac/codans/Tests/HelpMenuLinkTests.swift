import Foundation
import Testing

@testable import Codans

/// Pins the help-menu link definition shared by the sidebar footer menu and
/// the menubar Help menu, and the prefilled Report-issue URL.
@MainActor
struct HelpMenuLinkTests {
  private static let environment = HelpEnvironment(
    appVersion: "1.2.3",
    appBuild: "456",
    macOSVersion: "26.1.0",
    architecture: "arm64"
  )

  @Test
  func linksAreOrderedWebsiteReportIssueChangelog() {
    #expect(HelpMenuLink.allCases == [.website, .reportIssue, .changelog])
    #expect(HelpMenuLink.allCases.map(\.title) == ["Website", "Report issue", "Changelog"])
  }

  @Test
  func websiteAndChangelogPointAtTheSite() {
    #expect(HelpMenuLink.website.url(in: Self.environment).absoluteString == "https://codans.dev")
    #expect(
      HelpMenuLink.changelog.url(in: Self.environment).absoluteString
        == "https://codans.dev/changelog")
  }

  @Test
  func reportIssueOpensTheNewIssuePageWithOnlyABodyQuery() throws {
    let url = HelpMenuLink.reportIssue.url(in: Self.environment)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "https")
    #expect(components.host == "github.com")
    #expect(components.path == "/wanggang316/codans/issues/new")
    #expect(components.queryItems?.map(\.name) == ["body"])
  }

  @Test
  func reportIssueBodyCarriesTheEnvironment() throws {
    let body = try Self.decodedBody(HelpMenuLink.reportIssue.url(in: Self.environment))
    #expect(body == HelpMenuLink.issueBody(for: Self.environment))
    #expect(body.contains("codans: 1.2.3 (456)"))
    #expect(body.contains("macOS: 26.1.0"))
    #expect(body.contains("Architecture: arm64"))
  }

  @Test
  func reportIssueBodyEncodesReservedCharacters() throws {
    // `&`, `=`, `+` and `#` are legal inside a query, so a lax encoder leaves
    // them raw and GitHub then splits or truncates the body.
    let environment = HelpEnvironment(
      appVersion: "1.0 beta+1", appBuild: "a&b=c#d", macOSVersion: "26.1.0", architecture: "arm64")
    let url = HelpMenuLink.reportIssue.url(in: environment)
    let query = try #require(url.query(percentEncoded: true))
    #expect(query.hasPrefix("body="))
    let encodedValue = query.dropFirst("body=".count)
    for raw in [" ", "\n", "&", "=", "+", "#", "(", ")"] {
      #expect(!encodedValue.contains(raw), "unencoded \(raw.debugDescription)")
    }
    let body = try Self.decodedBody(url)
    #expect(body.contains("codans: 1.0 beta+1 (a&b=c#d)"))
  }

  @Test
  func currentEnvironmentIsFilled() {
    let current = HelpEnvironment.current
    #expect(!current.macOSVersion.isEmpty)
    #expect(["arm64", "x86_64"].contains(current.architecture))
  }

  private static func decodedBody(_ url: URL) throws -> String {
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return try #require(components.queryItems?.first { $0.name == "body" }?.value)
  }
}
