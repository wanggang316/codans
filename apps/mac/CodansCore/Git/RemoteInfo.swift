import Foundation

/// Host and full repository path parsed from a git remote URL. The Code Host layer turns
/// it into a `CodeHostRepository` once the resolver knows which Code Host serves `host`.
/// A pure parser with fixture-backed tests keeps this free of any remote API.
///
/// Recognised URL shapes (all are emitted by `git remote get-url origin` depending on
/// how the remote was added):
///
///   git@github.com:owner/repo.git
///   https://github.com/owner/repo.git
///   ssh://git@github.com/owner/repo.git
///   https://github.com/owner/repo          (no .git suffix)
///   git@gitlab.com:group/sub/repo.git      (nested groups)
///
/// `path` keeps every segment (`group/sub/repo`), because GitLab projects can live in
/// nested groups (ADR 0004 item 12). A trailing `.git` is removed.
///
/// The parser does not filter on the host: GitHub Enterprise Server and self-managed
/// GitLab expose the same schemes at other hosts. The Code Host resolver decides whether
/// the host is one codans supports.
///
/// `nonisolated` because the type + parser are pure value-construction work with no actor
/// concerns.
public nonisolated struct RemoteInfo: Equatable, Hashable, Sendable {
  public let host: String
  /// Full repository path without a leading slash or a `.git` suffix, for example
  /// `owner/repo` or `group/sub/repo`. Always has at least two segments.
  public let path: String
  /// `true` for SCP-style (`git@host:path`) and `ssh://` remotes. Their `host` is an SSH
  /// host, which can be an alias from `~/.ssh/config`, and their port is the SSH port.
  public let isSSH: Bool

  public init(host: String, path: String, isSSH: Bool = false) {
    self.host = host
    self.path = path
    self.isSSH = isSSH
  }

  /// Parses a git remote URL into a `RemoteInfo`. Throws `RemoteInfo.ParseError.malformed` on
  /// any shape we do not recognise. The error is local to this type (rather than reusing the
  /// app-module `GitError`) so the parser can live in `CodansCore` and be reused by the
  /// CLI without dragging a cross-module import; the app-layer `LiveGitService` translates
  /// `ParseError` into `GitError.malformedRemoteURL` at the service boundary.
  public static func parse(_ urlString: String) throws -> RemoteInfo {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ParseError.malformed(urlString)
    }

    // Dispatch on URL shape. The SCP-style (`git@host:path`) case must be handled
    // before the generic URL parser: `URL(string:)` accepts `git@host:owner/repo` but
    // decodes `host:path` as "scheme=git@host" which is not useful.
    if let info = try Self.parseSCPStyle(trimmed) { return info }
    if let info = try Self.parseSchemeStyle(trimmed) { return info }
    throw ParseError.malformed(urlString)
  }

  /// Error raised when `parse(_:)` cannot interpret the input. Payload is the original string
  /// so callers can echo it back to the user or write it to a log line.
  public nonisolated enum ParseError: Error, Equatable, Sendable {
    case malformed(String)
  }

  // MARK: - Private parsers

  /// Parses `git@<host>:<path>[.git]`. Returns nil if the input does not start with a
  /// user-at-host SCP shape so the caller can try the URL-scheme parser. Throws for SCP-shaped
  /// inputs whose body is malformed (fewer than two path segments).
  private static func parseSCPStyle(_ input: String) throws -> RemoteInfo? {
    // Detect the SCP shape: "<user>@<host>:<path>". The colon cannot follow a slash, and the
    // whole input must not contain "://" (that's the scheme-URL form).
    guard !input.contains("://") else { return nil }
    guard let colonIndex = input.firstIndex(of: ":") else { return nil }
    let head = input[..<colonIndex]
    guard head.contains("@") else { return nil }

    let afterColon = input[input.index(after: colonIndex)...]
    guard let atIndex = head.firstIndex(of: "@") else {
      throw ParseError.malformed(input)
    }
    let host = String(head[head.index(after: atIndex)...])
    return try Self.makeInfo(host: host, path: String(afterColon), isSSH: true, original: input)
  }

  /// Parses `<scheme>://[user@]<host>/<path>[.git]` where scheme is https, http, or
  /// ssh. Returns nil when no recognised scheme is present (for the SCP-style fallback).
  private static func parseSchemeStyle(_ input: String) throws -> RemoteInfo? {
    let lower = input.lowercased()
    let schemes = ["https://", "http://", "ssh://", "git://"]
    guard schemes.contains(where: { lower.hasPrefix($0) }) else { return nil }

    // Strip the scheme prefix.
    guard let schemeEnd = input.range(of: "://") else { return nil }
    var remainder = String(input[schemeEnd.upperBound...])

    // Strip the optional `user@` authority.
    if let atIndex = remainder.firstIndex(of: "@"),
      let slashIndex = remainder.firstIndex(of: "/"),
      atIndex < slashIndex
    {
      remainder = String(remainder[remainder.index(after: atIndex)...])
    }

    // Split `<host>/<path>` on the first `/`.
    guard let firstSlash = remainder.firstIndex(of: "/") else {
      throw ParseError.malformed(input)
    }
    let host = String(remainder[..<firstSlash])
    let path = String(remainder[remainder.index(after: firstSlash)...])
    return try Self.makeInfo(host: host, path: path, isSSH: lower.hasPrefix("ssh://"), original: input)
  }

  /// Builds a `RemoteInfo` from a separated `host` and remainder `path` string. Trims a
  /// trailing `.git`; rejects any remainder that does not have at least two path segments.
  private static func makeInfo(host: String, path: String, isSSH: Bool, original: String) throws -> RemoteInfo {
    guard !host.isEmpty else { throw ParseError.malformed(original) }
    var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard components.count >= 2 else { throw ParseError.malformed(original) }
    if components[components.count - 1].hasSuffix(".git") {
      components[components.count - 1].removeLast(4)
    }
    guard components.allSatisfy({ !$0.isEmpty }) else {
      throw ParseError.malformed(original)
    }
    return RemoteInfo(host: host, path: components.joined(separator: "/"), isSSH: isSSH)
  }
}
