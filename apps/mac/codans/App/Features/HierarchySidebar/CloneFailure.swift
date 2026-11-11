import Foundation

/// What the Clone Repository sheet shows for a failed `git clone`. A known
/// authentication failure gets a short `summary` with the next step and keeps
/// git's own output as `detail`; any other failure shows git's output as the
/// summary, with no detail.
nonisolated struct CloneFailure: Equatable, Sendable {
  var summary: String
  var detail: String?

  init(summary: String, detail: String? = nil) {
    self.summary = summary
    self.detail = detail
  }

  /// Classifies git's stderr for a clone of `remoteURL`.
  init(stderr: String, remoteURL: String) {
    let raw = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
      self.init(summary: "git clone failed.")
      return
    }
    let remote = CloneRemote(remoteURL)
    let lowered = raw.lowercased()
    if Self.hostKeyMarkers.contains(where: lowered.contains) {
      self.init(summary: Self.hostKeySummary(remote), detail: raw)
    } else if Self.publicKeyMarkers.contains(where: lowered.contains) {
      self.init(summary: Self.publicKeySummary(remote), detail: raw)
    } else if Self.httpCredentialMarkers.contains(where: lowered.contains) {
      self.init(summary: Self.httpCredentialSummary(remote), detail: raw)
    } else {
      self.init(summary: raw)
    }
  }

  // Lowercased fragments of git, curl, and ssh messages.
  private static let httpCredentialMarkers = [
    "could not read username",
    "could not read password",
    "terminal prompts disabled",
    "authentication failed",
    "http basic: access denied",
    "the requested url returned error: 401",
    "the requested url returned error: 403",
  ]
  private static let publicKeyMarkers = ["permission denied (publickey"]
  private static let hostKeyMarkers = ["host key verification failed"]

  private static func httpCredentialSummary(_ remote: CloneRemote) -> String {
    let host = remote.hostAndPort ?? "this host"
    let nextStep: String
    switch remote.platform {
    case .github:
      nextStep = "Run `gh auth login` in a terminal, then clone again."
    case .gitlab:
      nextStep = "Run `glab auth login --hostname \(host)` in a terminal, then clone again."
    case .other:
      nextStep =
        "Set up a git credential helper for \(host) (for example `git config --global credential.helper osxkeychain`), sign in once in a terminal, then clone again."
    }
    return "git has no valid credentials for \(host). \(nextStep)"
  }

  private static func publicKeySummary(_ remote: CloneRemote) -> String {
    let host = remote.host ?? "the host"
    return "\(host) rejected the SSH key. Add your SSH public key to your account on \(host), then clone again."
  }

  private static func hostKeySummary(_ remote: CloneRemote) -> String {
    guard let host = remote.host else {
      return "The SSH host key is not trusted yet. "
        + "Connect to the host once in a terminal to accept its key, then clone again."
    }
    let port = remote.port.map { "-p \($0) " } ?? ""
    let target = remote.user.map { "\($0)@\(host)" } ?? host
    return "The SSH host key of \(host) is not trusted yet. "
      + "Run `ssh \(port)-T \(target)` in a terminal to accept it, then clone again."
  }
}

/// The parts of a clone URL the failure message needs. Handles URL forms
/// (`https://host:port/owner/repo`, `ssh://user@host:port/owner/repo`) and
/// scp-style (`user@host:owner/repo`).
private nonisolated struct CloneRemote {
  enum Platform { case github, gitlab, other }

  var user: String?
  var host: String?
  var port: Int?

  init(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("://") {
      let components = URLComponents(string: trimmed)
      user = components?.user
      host = components?.host
      port = components?.port
    } else if let colon = trimmed.firstIndex(of: ":") {
      let authority = trimmed[..<colon]
      if let at = authority.lastIndex(of: "@") {
        user = String(authority[..<at])
        host = String(authority[authority.index(after: at)...])
      } else {
        host = String(authority)
      }
    }
    if host?.isEmpty == true { host = nil }
  }

  var hostAndPort: String? {
    guard let host else { return nil }
    return port.map { "\(host):\($0)" } ?? host
  }

  var platform: Platform {
    let name = host?.lowercased() ?? ""
    if name.contains("github") { return .github }
    if name.contains("gitlab") { return .gitlab }
    return .other
  }
}
