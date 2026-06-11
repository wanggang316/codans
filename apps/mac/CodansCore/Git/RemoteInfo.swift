import Foundation

/// Host / owner / repo triple parsed from a git remote URL. The GitHub integration's batched
/// GraphQL fetcher needs these three strings to target the right `gh api graphql --hostname`
/// host + `(owner, repo)` variables — and it needs them without taking a dependency on any
/// remote API. A pure parser with fixture-backed tests is the cheapest way to satisfy both.
///
/// Recognised URL shapes (all three are emitted by `git remote get-url origin` depending on
/// how the remote was added):
///
///   git@github.com:owner/repo.git
///   https://github.com/owner/repo.git
///   ssh://git@github.com/owner/repo.git
///   https://github.com/owner/repo          (no .git suffix)
///   git@github.com:owner/repo              (no .git suffix)
///
/// Non-GitHub hostnames are accepted — the parser does not filter on `github.com`, because a
/// GHES (GitHub Enterprise Server) install exposes the same schemes at an alternate host. The
/// caller decides whether the host is one it supports.
///
/// `nonisolated` because the type + parser are pure value-construction work with no actor
/// concerns.
public nonisolated struct RemoteInfo: Equatable, Hashable, Sendable {
  public let host: String
  public let owner: String
  public let repo: String

  public init(host: String, owner: String, repo: String) {
    self.host = host
    self.owner = owner
    self.repo = repo
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

    // Dispatch on URL shape. The SCP-style (`git@host:owner/repo`) case must be handled
    // before the generic URL parser: `URL(string:)` accepts `git@host:owner/repo` but
    // decodes `host:owner/repo` as "scheme=git@host, path=owner/repo" which is not useful.
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

  /// Parses `git@<host>:<owner>/<repo>[.git]`. Returns nil if the input does not start with a
  /// user-at-host SCP shape so the caller can try the URL-scheme parser. Throws for SCP-shaped
  /// inputs whose body is malformed (e.g. missing owner, missing repo).
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
    return try Self.makeInfo(host: host, path: String(afterColon), original: input)
  }

  /// Parses `<scheme>://[user@]<host>/<owner>/<repo>[.git]` where scheme is https, http, or
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

    // Split `<host>/<owner>/<repo>...` on the first `/`.
    guard let firstSlash = remainder.firstIndex(of: "/") else {
      throw ParseError.malformed(input)
    }
    let host = String(remainder[..<firstSlash])
    let path = String(remainder[remainder.index(after: firstSlash)...])
    return try Self.makeInfo(host: host, path: path, original: input)
  }

  /// Builds a `RemoteInfo` from a separated `host` and remainder `path` string. Trims a
  /// trailing `.git`; rejects any remainder that does not have at least two path segments.
  private static func makeInfo(host: String, path: String, original: String) throws -> RemoteInfo {
    guard !host.isEmpty else { throw ParseError.malformed(original) }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2 else { throw ParseError.malformed(original) }
    let owner = String(components[0])
    var repo = String(components[1])
    if repo.hasSuffix(".git") { repo.removeLast(4) }
    guard !owner.isEmpty, !repo.isEmpty else {
      throw ParseError.malformed(original)
    }
    return RemoteInfo(host: host, owner: owner, repo: repo)
  }
}
