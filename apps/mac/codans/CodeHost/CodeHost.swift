import CodansCore
import Foundation

/// One Code Host implementation (`GitHubCodeHost`, `GitLabCodeHost`). All Code Host behavior that
/// the reducer and the views use goes through this protocol, so they do not branch on the
/// Code Host kind. See ADR 0004 items 5 and 11.
///
/// Rules every implementation follows:
/// - Reach the Code Host only through its CLI and the shared `CommandRunner`. User input
///   (branch names, numbers) is always an argv element, never interpolated into a shell.
/// - Address a repository explicitly (`CodeHostRepository` / `PullRequestReference`);
///   never resolve it from the subprocess working directory.
/// - Only the implementation's decoding layer knows the Code Host's wire values. It
///   returns the provider-neutral model from `CodansCore`.
/// - Express capability differences as data on `PullRequestSnapshot` (merge options,
///   rerun capability). The protocol has no optional methods.
///
/// Reads return a value or throw `CodeHostError`. Writes return on success and throw on
/// any failure.
nonisolated protocol CodeHost: Sendable {
  /// Probes whether the CLI is installed and logged in. Never throws — the failure is the
  /// `.unavailable` case of the returned enum.
  func availability() async -> CodeHostAvailability

  /// Hosts the CLI is logged in to. The resolver uses it to recognise self-managed
  /// instances. Empty when the CLI is missing or logged in nowhere.
  func authenticatedHosts() async -> Set<String>

  /// Batched Pull Request lookup for one repository and a list of source branch names.
  /// Returns `[branch: PullRequestSnapshot]` for every branch that resolves to a Pull
  /// Request after the fork filter. Branches with no Pull Request are absent (never
  /// nil-valued). Empty `branches` returns `[:]` without spawning a subprocess.
  func batchPullRequests(
    repository: CodeHostRepository, branches: [String]
  ) async throws -> [String: PullRequestSnapshot]

  /// Merges the Pull Request with the given strategy. Throws `.mergeConflict` when the
  /// Code Host reports it cannot merge cleanly.
  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy) async throws

  /// Closes the Pull Request without merging.
  func close(_ pullRequest: PullRequestReference) async throws

  /// Promotes a draft Pull Request to ready for review.
  func markReady(_ pullRequest: PullRequestReference) async throws

  /// Reruns the failed checks of the Pull Request's latest CI run (GitHub: the failed
  /// Actions runs on the head commit; GitLab: a retry of the head pipeline).
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws

  /// Web page of the repository.
  func repositoryWebURL(_ repository: CodeHostRepository) -> URL?

  /// Web page of the Pull Request.
  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL?
}

/// Gives the Code Host of a remote: `publicHost` of a kind, or a host that kind's CLI is
/// logged in to; then the Project's Code Host choice; otherwise none. Kinds are tried in
/// `CodeHostKind.allCases` order, so a host known to two CLIs resolves to the first kind.
/// See ADR 0004 item 2.
///
/// The logged-in hosts of each kind are asked once and cached; `invalidate()` drops the
/// cache so a `gh auth login` is seen after the Settings "Re-check".
actor CodeHostResolver {
  typealias HostsProvider = @Sendable (CodeHostKind) async -> Set<String>

  private let hostsProvider: HostsProvider
  private var cachedHosts: [CodeHostKind: Task<Set<String>, Never>] = [:]

  init(hostsProvider: @escaping HostsProvider) {
    self.hostsProvider = hostsProvider
  }

  /// The Code Host repository for `remote`, or `nil` when no Code Host serves its host.
  /// `choice` is the Project's Code Host setting (`nil` is Auto). It applies only when
  /// neither CLI step matches, so it cannot move a known host to another kind.
  func resolve(_ remote: RemoteInfo, choice: CodeHostKind? = nil) async -> CodeHostRepository? {
    let host = remote.host.lowercased()
    for kind in CodeHostKind.allCases {
      if host == kind.publicHost {
        return CodeHostRepository(kind: kind, host: remote.host, path: remote.path)
      }
      let known = await authenticatedHosts(for: kind)
      if known.contains(host) {
        return CodeHostRepository(kind: kind, host: remote.host, path: remote.path)
      }
    }
    return choice.map { CodeHostRepository(kind: $0, host: remote.host, path: remote.path) }
  }

  func invalidate() {
    cachedHosts = [:]
  }

  private func authenticatedHosts(for kind: CodeHostKind) async -> Set<String> {
    if let task = cachedHosts[kind] { return await task.value }
    let provider = hostsProvider
    let task = Task { Set(await provider(kind).map { $0.lowercased() }) }
    cachedHosts[kind] = task
    return await task.value
  }
}
