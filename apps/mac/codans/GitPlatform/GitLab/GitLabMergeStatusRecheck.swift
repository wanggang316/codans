import Foundation

/// Decides which merge requests to ask GitLab to recheck after a batched read.
///
/// GitLab marks open merge requests `UNCHECKED` when their target branch moves and
/// checks them again only when something asks (`with_merge_status_recheck=true`, or a
/// browser opening the page). Until then codans reads an unknown merge state: the merge
/// buttons stay off and the unit stays in the hot poll tier. A recheck makes the next
/// read return the real status.
///
/// Limits, so a project with many unchecked merge requests does not flood the API:
/// - one recheck per merge request per `cooldown`;
/// - at most `maxPerBatch` rechecks per batched read;
/// - `CHECKING` is GitLab's own check in progress, so it is rechecked only when it has
///   not settled for `cooldown`.
nonisolated final class GitLabMergeStatusRecheck: @unchecked Sendable {
  /// One merge request, as the batched read saw it.
  struct Candidate: Hashable, Sendable {
    var host: String
    var projectPath: String
    var iid: Int
    var detailedMergeStatus: String?
  }

  static let cooldown: TimeInterval = 60
  static let maxPerBatch = 3

  private struct Key: Hashable {
    var host: String
    var projectPath: String
    var iid: Int
  }

  private struct Entry {
    var unsettledSince: Date
    var lastRecheck: Date?
  }

  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]

  /// The merge requests to recheck now, at most `maxPerBatch`, and records the recheck
  /// time for each. The least recently rechecked go first (never rechecked before any
  /// other), so a project with more unchecked merge requests than the cap rechecks
  /// every one of them in turn. A merge request that is no longer unsettled is
  /// forgotten, so a later target branch move starts a new cycle.
  func claim(_ candidates: [Candidate], now: Date) -> [Candidate] {
    lock.withLock {
      var due: [(candidate: Candidate, key: Key, lastRecheck: Date)] = []
      for candidate in candidates {
        let key = Key(
          host: candidate.host.lowercased(), projectPath: candidate.projectPath.lowercased(), iid: candidate.iid)
        let status = candidate.detailedMergeStatus
        guard status == "UNCHECKED" || status == "CHECKING" else {
          entries[key] = nil
          continue
        }
        let entry = entries[key] ?? Entry(unsettledSince: now)
        entries[key] = entry
        if let last = entry.lastRecheck, now.timeIntervalSince(last) < Self.cooldown { continue }
        if status == "CHECKING", entry.lastRecheck == nil, now.timeIntervalSince(entry.unsettledSince) < Self.cooldown {
          continue
        }
        due.append((candidate, key, entry.lastRecheck ?? .distantPast))
      }
      // Least recently rechecked first; the caller's order breaks ties.
      let claimed = due.enumerated()
        .sorted { ($0.element.lastRecheck, $0.offset) < ($1.element.lastRecheck, $1.offset) }
        .prefix(Self.maxPerBatch)
        .map(\.element)
      for item in claimed {
        entries[item.key]?.lastRecheck = now
      }
      return claimed.map(\.candidate)
    }
  }
}
