import Foundation
import Testing
import CodansCore

@testable import Codans

struct GitHubJSONParsersTests {
  // MARK: - gh auth status

  @Test
  func parseAuthStatusAvailableReturnsHostAndUser() throws {
    let data = try Self.loadFixture("gh-auth-status-available")
    let result = try GitHubJSONParsers.parseAuthStatus(data)
    #expect(result?.host == "github.com")
    #expect(result?.user == "gump")
  }

  @Test
  func parseAuthStatusUnauthReturnsNil() throws {
    let data = try Self.loadFixture("gh-auth-status-unauth")
    let result = try GitHubJSONParsers.parseAuthStatus(data)
    #expect(result == nil)
  }

  // MARK: - splitCheckState (shared between retired parseChecks and statusCheckRollup)

  @Test
  func splitCheckStateUnknownFallsBackToPending() {
    let (status, conclusion) = GitHubJSONParsers.splitCheckState("something-new")
    #expect(status == .inProgress)
    #expect(conclusion == nil)
  }

  @Test
  func splitCheckStateHandlesCaseVariants() {
    #expect(GitHubJSONParsers.splitCheckState("success").0 == .completed)
    #expect(GitHubJSONParsers.splitCheckState("failed").1 == .failure)
    #expect(GitHubJSONParsers.splitCheckState("canceled").1 == .cancelled)
  }

  // MARK: - Helpers

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
