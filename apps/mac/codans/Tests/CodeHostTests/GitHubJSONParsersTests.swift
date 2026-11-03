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

  // MARK: - gh run list

  @Test
  func parseLatestWorkflowRunSuccess() throws {
    let data = try Self.loadFixture("gh-run-list-success")
    let run = try GitHubJSONParsers.parseLatestWorkflowRun(data)
    let unwrapped = try #require(run)
    #expect(unwrapped.databaseID == 123_456_789)
    #expect(unwrapped.status == .completed)
    #expect(unwrapped.conclusion == .success)
    #expect(unwrapped.headBranch == "feature/github01")
    #expect(unwrapped.runNumber == 42)
  }

  @Test
  func parseLatestWorkflowRunFailure() throws {
    let data = try Self.loadFixture("gh-run-list-failure")
    let run = try GitHubJSONParsers.parseLatestWorkflowRun(data)
    let unwrapped = try #require(run)
    #expect(unwrapped.conclusion == .failure)
    #expect(unwrapped.databaseID == 987_654_321)
  }

  @Test
  func parseLatestWorkflowRunEmptyReturnsNil() throws {
    let data = try Self.loadFixture("gh-run-list-empty")
    let run = try GitHubJSONParsers.parseLatestWorkflowRun(data)
    #expect(run == nil)
  }

  // MARK: - Malformed input

  @Test
  func parseLatestWorkflowRunOnNonJSONThrowsCodeHostError() {
    let data = Data("not json".utf8)
    do {
      _ = try GitHubJSONParsers.parseLatestWorkflowRun(data)
      Issue.record("expected .other throw")
    } catch let error as CodeHostError {
      if case .other = error { return }
      Issue.record("expected .other, got \(error)")
    } catch {
      Issue.record("expected CodeHostError, got \(type(of: error))")
    }
  }

  // MARK: - Fixture loading

  private static func loadFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures", isDirectory: true)
      .appendingPathComponent("\(name).json", isDirectory: false)
    return try Data(contentsOf: url)
  }
}
