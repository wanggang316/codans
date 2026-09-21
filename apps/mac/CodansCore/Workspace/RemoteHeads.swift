import Foundation

/// Branches a remote advertises, read with
/// `git ls-remote --symref <url> HEAD refs/heads/*` before anything is
/// cloned. Lets a workspace member from a URL offer the same ref choices a
/// local repository does.
public nonisolated struct RemoteHeads: Equatable, Sendable {
  /// Branch the remote's HEAD points at, when it advertises one.
  public var defaultBranch: String?
  /// Branch names without the `refs/heads/` prefix, sorted.
  public var branches: [String]

  public init(defaultBranch: String? = nil, branches: [String] = []) {
    self.defaultBranch = defaultBranch
    self.branches = branches
  }

  /// Parses `ls-remote --symref` output. Lines look like
  /// `ref: refs/heads/main\tHEAD` (the symref, first when present) and
  /// `<sha>\trefs/heads/feature`. Anything else — `HEAD` itself, tags,
  /// peeled refs — is ignored.
  public static func parse(lsRemoteOutput output: String) -> RemoteHeads {
    var defaultBranch: String?
    var branches: [String] = []
    let headsPrefix = "refs/heads/"
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      let columns = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
      guard columns.count == 2 else { continue }
      let left = String(columns[0])
      let right = String(columns[1])
      if left.hasPrefix("ref: "), right == "HEAD" {
        let target = String(left.dropFirst("ref: ".count))
        if target.hasPrefix(headsPrefix) {
          defaultBranch = String(target.dropFirst(headsPrefix.count))
        }
        continue
      }
      guard right.hasPrefix(headsPrefix), !right.hasSuffix("^{}") else { continue }
      let name = String(right.dropFirst(headsPrefix.count))
      if !name.isEmpty, !branches.contains(name) {
        branches.append(name)
      }
    }
    branches.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    return RemoteHeads(defaultBranch: defaultBranch, branches: branches)
  }
}
