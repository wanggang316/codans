import Foundation

/// Final decision of a pull request's review process, as reported by GraphQL's
/// `PullRequest.reviewDecision`. Optional at the field level — a PR with no required
/// reviewers has nil decision, which is different from `.reviewRequired` (a decision that
/// actively blocks merge).
///
/// Raw values mirror GitHub's enum strings so JSON decode is a one-hop pass-through.
public nonisolated enum ReviewDecision: String, Codable, Sendable, CaseIterable {
  case approved = "APPROVED"
  case changesRequested = "CHANGES_REQUESTED"
  case reviewRequired = "REVIEW_REQUIRED"

  /// Decode a raw string, mapping unrecognised values to nil rather than crashing. Paired
  /// with `decodeIfPresent` in the parser — a missing field decodes to nil; a present but
  /// unknown raw value also decodes to nil.
  public static func decodeOrNil(_ raw: String?) -> ReviewDecision? {
    guard let raw, !raw.isEmpty else { return nil }
    return ReviewDecision(rawValue: raw)
  }
}
