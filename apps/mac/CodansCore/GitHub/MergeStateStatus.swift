import Foundation

/// GitHub's richer merge-state classification — reported by the GraphQL `PullRequest.mergeStateStatus`
/// field. Strictly more informative than the legacy `MergeableState` (which only knows
/// mergeable / conflicting / unknown): `.blocked` surfaces "required status checks haven't
/// passed yet", `.behind` surfaces "base branch has moved forward since this PR was last
/// rebased", and so on. The PR popover uses these to explain precisely *why* the merge
/// button is disabled.
///
/// Raw values mirror GitHub's enum strings so JSON decode is a one-hop pass-through.
/// `.unknown` is both the GitHub-reported "still computing" state and the decode fallback
/// for any raw value we don't recognise (GitHub adds cases; we must not crash).
public nonisolated enum MergeStateStatus: String, Codable, Sendable, CaseIterable {
  case clean = "CLEAN"
  case dirty = "DIRTY"
  case blocked = "BLOCKED"
  case behind = "BEHIND"
  case hasHooks = "HAS_HOOKS"
  case unstable = "UNSTABLE"
  case draft = "DRAFT"
  case unknown = "UNKNOWN"

  /// Decode a raw string, mapping anything unrecognised to `.unknown`. Gives us forward
  /// compatibility with new cases GitHub may add without a crash. Call sites that need the
  /// raw Codable path (KeyedDecodingContainer.decode) should prefer this helper; the
  /// synthesized `init(rawValue:)` returns nil on unknown raw values.
  public static func decodeOrUnknown(_ raw: String?) -> MergeStateStatus {
    guard let raw else { return .unknown }
    return MergeStateStatus(rawValue: raw) ?? .unknown
  }
}
