import CodansCore
import Foundation

/// One Git Platform implementation (`GitHubGitPlatform`, `GitLabGitPlatform`). All Git Platform behavior that
/// the reducer and the views use goes through this protocol, so they do not branch on the
/// Git Platform kind. See ADR 0004 items 5 and 11.
///
/// Rules every implementation follows:
/// - Reach the Git Platform only through its CLI and the shared `CommandRunner`. User input
///   (branch names, numbers) is always an argv element, never interpolated into a shell.
/// - Address a repository explicitly (`GitPlatformRepository` / `PullRequestReference`);
///   never resolve it from the subprocess working directory.
/// - Only the implementation's decoding layer knows the Git Platform's wire values. It
///   returns the provider-neutral model from `CodansCore`.
/// - Express capability differences as data on `PullRequestSnapshot` (merge options,
///   rerun capability). The protocol has no optional methods.
///
/// Reads return a value or throw `GitPlatformError`. Writes return on success and throw on
/// any failure.
nonisolated protocol GitPlatform: Sendable {
  /// Probes whether the CLI is installed and logged in. Never throws — the failure is the
  /// `.unavailable` case of the returned enum.
  func availability() async -> GitPlatformAvailability

  /// Hosts the CLI is logged in to. The resolver uses it to recognise self-managed
  /// instances. Empty when the CLI is missing or logged in nowhere.
  func authenticatedHosts() async -> Set<String>

  /// Batched Pull Request lookup for one repository and a list of source branch names.
  /// Returns `[branch: PullRequestSnapshot]` for every branch that resolves to a Pull
  /// Request after the fork filter. Branches with no Pull Request are absent (never
  /// nil-valued). Empty `branches` returns `[:]` without spawning a subprocess.
  func batchPullRequests(
    repository: GitPlatformRepository, branches: [String]
  ) async throws -> [String: PullRequestSnapshot]

  /// Merges the Pull Request with the given strategy. Throws `.mergeConflict` when the
  /// Git Platform reports it cannot merge cleanly.
  func merge(_ pullRequest: PullRequestReference, strategy: MergeStrategy) async throws

  /// Closes the Pull Request without merging.
  func close(_ pullRequest: PullRequestReference) async throws

  /// Promotes a draft Pull Request to ready for review.
  func markReady(_ pullRequest: PullRequestReference) async throws

  /// Reruns the failed checks of the Pull Request's latest CI run (GitHub: the failed
  /// Actions runs on the head commit; GitLab: a retry of the head pipeline).
  func rerunFailedChecks(_ pullRequest: PullRequestReference) async throws

  /// Web page of the repository.
  func repositoryWebURL(_ repository: GitPlatformRepository) -> URL?

  /// Web page of the Pull Request.
  func pullRequestWebURL(_ pullRequest: PullRequestReference) -> URL?
}

/// Gives the Git Platform of a remote (ADR 0005 item 3):
/// 1. A Git Platform alias for its host: the alias's kind and API host.
/// 2. `github.com` or a host `gh` is logged in to: GitHub.
/// 3. `gitlab.com` or a host `glab` is logged in to: GitLab.
/// 4. For an SSH remote only: the `HostName` from `ssh -G`, matched without the port to the
///    one logged-in or public host of steps 2 and 3. This covers an alias from
///    `~/.ssh/config` (`git@github-work:…`) and an SSH port that is not the API port.
/// 5. Otherwise: none.
///
/// An alias resolves even when its API host is not logged in, so the fetch fails with the
/// login message in the badge position.
///
/// The logged-in hosts of each kind and the `ssh -G` results are asked once and cached;
/// `invalidate()` drops both, so a `gh auth login` or a change to `~/.ssh/config` is seen
/// after the Settings "Re-check".
actor GitPlatformResolver {
  typealias HostsProvider = @Sendable (GitPlatformKind) async -> Set<String>
  typealias SSHHostNameProvider = @Sendable (String) async -> String?

  private let hostsProvider: HostsProvider
  private let sshHostName: SSHHostNameProvider
  private var cachedHosts: [GitPlatformKind: Task<Set<String>, Never>] = [:]
  private var cachedSSHHostNames: [String: String?] = [:]

  init(hostsProvider: @escaping HostsProvider, sshHostName: @escaping SSHHostNameProvider = { _ in nil }) {
    self.hostsProvider = hostsProvider
    self.sshHostName = sshHostName
  }

  /// The Git Platform repository for `remote`, or `nil` when no Git Platform serves its host.
  func resolve(_ remote: RemoteInfo, aliases: [GitPlatformAlias] = []) async -> GitPlatformRepository? {
    let host = remote.host.lowercased()
    if let alias = Self.alias(for: remote, in: aliases) {
      return GitPlatformRepository(kind: alias.kind, host: alias.apiHost, path: remote.path)
    }
    for kind in GitPlatformKind.allCases {
      if host == kind.publicHost {
        return GitPlatformRepository(kind: kind, host: remote.host, path: remote.path)
      }
      let known = await authenticatedHosts(for: kind)
      if known.contains(host) {
        return GitPlatformRepository(kind: kind, host: remote.host, path: remote.path)
      }
    }
    guard remote.isSSH, let (kind, apiHost) = await apiHost(forSSHHost: host) else { return nil }
    return GitPlatformRepository(kind: kind, host: apiHost, path: remote.path)
  }

  /// The alias whose remote host is the remote's host. For an SSH remote the port is the
  /// SSH port, so an alias without a port also matches.
  static func alias(for remote: RemoteInfo, in aliases: [GitPlatformAlias]) -> GitPlatformAlias? {
    let host = GitPlatformAlias.normalizedHost(remote.host)
    if let exact = aliases.first(where: { $0.remoteHost == host }) { return exact }
    guard remote.isSSH else { return nil }
    let name = nameWithoutPort(host)
    return aliases.first { $0.remoteHost == name }
  }

  func invalidate() {
    cachedHosts = [:]
    cachedSSHHostNames = [:]
  }

  /// The one logged-in or public host, of any kind, whose name without port is the
  /// `HostName` of `sshHost`, or `nil`. A host that both CLIs know counts once, as
  /// GitHub, like steps 2 and 3.
  private func apiHost(forSSHHost sshHost: String) async -> (GitPlatformKind, String)? {
    let alias = Self.nameWithoutPort(sshHost)
    let resolved: String?
    if let cached = cachedSSHHostNames[alias] {
      resolved = cached
    } else {
      resolved = await sshHostName(alias)?.lowercased()
      cachedSSHHostNames[alias] = resolved
    }
    let name = resolved ?? alias
    var matches: [String: GitPlatformKind] = [:]
    for kind in GitPlatformKind.allCases {
      var candidates = await authenticatedHosts(for: kind)
      candidates.insert(kind.publicHost)
      for candidate in candidates where Self.nameWithoutPort(candidate) == name && matches[candidate] == nil {
        matches[candidate] = kind
      }
    }
    guard matches.count == 1, let (host, kind) = matches.first else { return nil }
    return (kind, host)
  }

  /// `host:port` → `host`. A bracketed IPv6 literal keeps its colons.
  static func nameWithoutPort(_ host: String) -> String {
    guard let colon = host.lastIndex(of: ":"), !host.hasSuffix("]"),
      host[host.index(after: colon)...].allSatisfy(\.isNumber)
    else { return host }
    return String(host[..<colon])
  }

  private func authenticatedHosts(for kind: GitPlatformKind) async -> Set<String> {
    if let task = cachedHosts[kind] { return await task.value }
    let provider = hostsProvider
    let task = Task { Set(await provider(kind).map { $0.lowercased() }) }
    cachedHosts[kind] = task
    return await task.value
  }
}
