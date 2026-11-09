import Foundation
import Testing

@testable import CodansCore

/// Codable round-trip tests for the provider-neutral Git Platform model. These types are
/// the snapshot-cache format; the GitHub wire mapping is tested in the app tier
/// (`GitHubWireTests`), because only the GitHub decoding layer knows wire values.
struct GitPlatformModelsCodableTests {
  // MARK: - Neutral raw values

  @Test
  func pullRequestStateRawValuesAreNeutral() {
    #expect(PullRequestState.open.rawValue == "open")
    #expect(PullRequestState.merged.rawValue == "merged")
    #expect(PullRequestState.closed.rawValue == "closed")
  }

  @Test
  func checkEnumsRoundTrip() throws {
    for status in CheckStatus.allCases {
      #expect(try Self.roundTrip(status) == status)
    }
    for conclusion in CheckConclusion.allCases {
      #expect(try Self.roundTrip(conclusion) == conclusion)
    }
  }

  @Test
  func githubWireStringsDoNotDecodeIntoTheNeutralModel() {
    // A v1 snapshot cache stored GitHub wire values; it must be discarded, not decoded.
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(PullRequestState.self, from: Data(#""OPEN""#.utf8))
    }
  }

  // MARK: - PullRequestSnapshot round-trip

  @Test
  func pullRequestSnapshotRoundTrip() throws {
    let snapshot = Self.makeSnapshot()
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded == snapshot)
    #expect(decoded.id == snapshot.number)
  }

  @Test
  func pullRequestSnapshotDraftRoundTrip() throws {
    var snapshot = Self.makeSnapshot()
    snapshot.isDraft = true
    snapshot.state = .open
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded.isDraft == true)
    #expect(decoded.state == .open)
  }

  @Test
  func pullRequestSnapshotMergedRoundTripPreservesMergeStateUnknown() throws {
    var snapshot = Self.makeSnapshot()
    snapshot.state = .merged
    snapshot.mergeState = .unknown
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded.state == .merged)
    #expect(decoded.mergeState.status == .unknown)
  }

  // MARK: - Snapshot fields

  @Test
  func pullRequestSnapshotInV1CacheShapeDoesNotDecode() {
    // The v1 cache shape (GitHub wire values, `mergeable`, no `mergeState`). Decoding
    // fails, so the snapshot cache drops the entry and the next fetch replaces it.
    let v1JSON = """
      {
        "number": 1234,
        "title": "Fix flaky terminal resize test",
        "state": "OPEN",
        "isDraft": false,
        "headRefName": "feature/github01",
        "author": "gump",
        "additions": 128,
        "deletions": 14,
        "commitCount": 3,
        "mergeable": "MERGEABLE",
        "url": "https://github.com/wanggang316/codans/pull/1234",
        "updatedAt": 1700000000
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(PullRequestSnapshot.self, from: Data(v1JSON.utf8))
    }
  }

  @Test
  func pullRequestSnapshotV2FieldsRoundTrip() throws {
    let snapshot = PullRequestSnapshot(
      number: 39,
      title: "feat(github): PR-centric integration",
      state: .merged,
      isDraft: false,
      headRefName: "feature/github01",
      author: "gump",
      additions: 5759,
      deletions: 73,
      commitCount: 12,
      url: URL(string: "https://github.com/wanggang316/codans/pull/39")!,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      checkRollup: [
        CheckResult(name: "build", status: .completed, conclusion: .success),
        CheckResult(name: "tests", status: .completed, conclusion: .failure),
      ],
      mergeState: PullRequestMergeState(status: .clean),
      mergeOptions: [
        PullRequestMergeOption(strategy: .squash, isEnabled: true),
        PullRequestMergeOption(strategy: .rebase, isEnabled: false, disabledReason: "Not allowed"),
      ],
      canRerunFailedChecks: true,
      reviewDecision: .approved,
      headRepositoryOwner: "wanggang316"
    )
    let decoded = try Self.roundTrip(snapshot)
    #expect(decoded == snapshot)
    #expect(decoded.checkRollup.count == 2)
    #expect(decoded.mergeState.status == .clean)
    #expect(decoded.reviewDecision == .approved)
    #expect(decoded.headRepositoryOwner == "wanggang316")
    #expect(decoded.mergeOption(for: .rebase)?.disabledReason == "Not allowed")
    #expect(decoded.canRerunFailedChecks)
  }

  @Test
  func headSHARoundTrips() throws {
    var snapshot = Self.makeSnapshot()
    snapshot.headSHA = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
    #expect(try Self.roundTrip(snapshot).headSHA == "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432")
  }

  /// A cache entry written before the snapshot had `headSHA` still decodes. Its head is
  /// unknown, so a merge refreshes it first.
  @Test
  func cacheEntryWithoutHeadSHADecodesWithNil() throws {
    var json = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.makeSnapshot())) as? [String: Any])
    json["headSHA"] = nil
    let data = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(PullRequestSnapshot.self, from: data)
    #expect(decoded.headSHA == nil)
    #expect(decoded.number == 1234)
  }

  @Test
  func hasMergeConflictFollowsMergeState() {
    var snapshot = Self.makeSnapshot()
    snapshot.mergeState = PullRequestMergeState(status: .conflicted, reason: "conflicts")
    #expect(snapshot.hasMergeConflict)
    snapshot.mergeState = PullRequestMergeState(status: .blocked)
    #expect(!snapshot.hasMergeConflict)
  }

  // MARK: - CheckResult round-trip

  @Test
  func checkResultCompletedSuccessRoundTrip() throws {
    let check = CheckResult(
      name: "build (macOS)",
      status: .completed,
      conclusion: .success,
      detailsURL: URL(string: "https://github.com/owner/repo/actions/runs/1/job/2")!,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000),
      completedAt: Date(timeIntervalSince1970: 1_700_000_120),
      durationSeconds: 120
    )
    let decoded = try Self.roundTrip(check)
    #expect(decoded == check)
  }

  @Test
  func checkResultPendingNoConclusionRoundTrip() throws {
    let check = CheckResult(name: "ui-snapshots", status: .inProgress)
    let decoded = try Self.roundTrip(check)
    #expect(decoded.status == .inProgress)
    #expect(decoded.conclusion == nil)
    #expect(decoded.detailsURL == nil)
  }

  @Test
  func checkResultIdCompositeFromNameAndStartedAt() {
    let a = CheckResult(name: "build", status: .completed, startedAt: Date(timeIntervalSince1970: 100))
    let b = CheckResult(name: "build", status: .completed, startedAt: Date(timeIntervalSince1970: 200))
    #expect(a.id != b.id, "same name, different start → distinct ids")
  }

  // MARK: - Helpers

  private static func makeSnapshot() -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: 1234,
      title: "Fix flaky terminal resize test",
      state: .open,
      isDraft: false,
      headRefName: "feature/github01",
      author: "gump",
      additions: 128,
      deletions: 14,
      commitCount: 3,
      url: URL(string: "https://github.com/wanggang316/codans/pull/1234")!,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoded = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: encoded)
  }
}
