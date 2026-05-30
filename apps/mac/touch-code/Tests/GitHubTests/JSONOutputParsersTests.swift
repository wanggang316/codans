import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

struct JSONOutputParsersTests {
  // MARK: - gh auth status

  @Test
  func parseAuthStatusAvailableReturnsHostAndUser() throws {
    let data = try Self.loadFixture("gh-auth-status-available")
    let result = try JSONOutputParsers.parseAuthStatus(data)
    #expect(result?.host == "github.com")
    #expect(result?.user == "gump")
  }

  @Test
  func parseAuthStatusUnauthReturnsNil() throws {
    let data = try Self.loadFixture("gh-auth-status-unauth")
    let result = try JSONOutputParsers.parseAuthStatus(data)
    #expect(result == nil)
  }

  // MARK: - splitCheckState (shared between retired parseChecks and statusCheckRollup)

  @Test
  func splitCheckStateUnknownFallsBackToPending() {
    let (status, conclusion) = JSONOutputParsers.splitCheckState("something-new")
    #expect(status == .inProgress)
    #expect(conclusion == nil)
  }

  @Test
  func splitCheckStateHandlesCaseVariants() {
    #expect(JSONOutputParsers.splitCheckState("success").0 == .completed)
    #expect(JSONOutputParsers.splitCheckState("failed").1 == .failure)
    #expect(JSONOutputParsers.splitCheckState("canceled").1 == .cancelled)
  }

  // MARK: - gh run list

  @Test
  func parseLatestWorkflowRunSuccess() throws {
    let data = try Self.loadFixture("gh-run-list-success")
    let run = try JSONOutputParsers.parseLatestWorkflowRun(data)
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
    let run = try JSONOutputParsers.parseLatestWorkflowRun(data)
    let unwrapped = try #require(run)
    #expect(unwrapped.conclusion == .failure)
    #expect(unwrapped.databaseID == 987_654_321)
  }

  @Test
  func parseLatestWorkflowRunEmptyReturnsNil() throws {
    let data = try Self.loadFixture("gh-run-list-empty")
    let run = try JSONOutputParsers.parseLatestWorkflowRun(data)
    #expect(run == nil)
  }

  // MARK: - Malformed input

  @Test
  func parseLatestWorkflowRunOnNonJSONThrowsGitHubError() {
    let data = Data("not json".utf8)
    do {
      _ = try JSONOutputParsers.parseLatestWorkflowRun(data)
      Issue.record("expected .other throw")
    } catch let error as GitHubError {
      if case .other = error { return }
      Issue.record("expected .other, got \(error)")
    } catch {
      Issue.record("expected GitHubError, got \(type(of: error))")
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
