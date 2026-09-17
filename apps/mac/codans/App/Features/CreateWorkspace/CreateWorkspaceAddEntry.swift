import Foundation

/// What the sheet's URL field was given, decided from the text alone plus
/// one existence check: a remote to clone or a folder on disk.
nonisolated enum AddEntryKind: Equatable, Sendable {
  case empty
  /// Normalized: `host.tld/owner/repo` gains `https://`.
  case url(String)
  /// Tilde-expanded. `exists == false` for a path with nothing behind it,
  /// so a typo is reported rather than probed.
  case path(String, exists: Bool)
  case unrecognized(String)
}

nonisolated enum AddEntryClassifier {
  /// Trims, then: URL forms first (a scheme, an scp-style `user@host:path`,
  /// or `host.tld/path`), then paths (`/`, `~`, `./`, `../`, or a slash
  /// with something at that path).
  static func classify(_ raw: String, fileExists: (String) -> Bool) -> AddEntryKind {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return .empty }
    if text.contains("://") || text.hasPrefix("git@") {
      return .url(text)
    }
    if let regex = try? Regex(#"^[^\s/:@]+@[^\s/:]+:[^\s]+$"#), text.wholeMatch(of: regex) != nil {
      return .url(text)
    }
    if text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix("./") || text.hasPrefix("../") {
      let expanded = (text as NSString).expandingTildeInPath
      return .path(expanded, exists: fileExists(expanded))
    }
    if let regex = try? Regex(#"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[^\s]+$"#), text.wholeMatch(of: regex) != nil {
      return .url("https://\(text)")
    }
    if text.contains("/"), fileExists(text) {
      return .path(text, exists: true)
    }
    return .unrecognized(text)
  }

  /// A key two spellings of one remote share, so `git@github.com:o/r.git`
  /// and `https://github.com/o/r` are the same member: host and path only,
  /// host lowercased, user and port dropped, trailing slash and `.git` gone.
  static func normalizedRemoteKey(_ url: String) -> String {
    var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix("/") { text.removeLast() }
    if text.lowercased().hasSuffix(".git") { text.removeLast(4) }
    while text.hasSuffix("/") { text.removeLast() }
    var authority: Substring
    var path: Substring
    if let range = text.range(of: "://") {
      let rest = text[range.upperBound...]
      if let slash = rest.firstIndex(of: "/") {
        authority = rest[..<slash]
        path = rest[rest.index(after: slash)...]
      } else {
        authority = rest
        path = ""
      }
    } else if let colon = text.firstIndex(of: ":") {
      authority = text[..<colon]
      path = text[text.index(after: colon)...]
      while path.hasPrefix("/") { path.removeFirst() }
    } else {
      return text
    }
    if let at = authority.lastIndex(of: "@") {
      authority = authority[authority.index(after: at)...]
    }
    if let port = authority.firstIndex(of: ":") {
      authority = authority[..<port]
    }
    return authority.lowercased() + "/" + path
  }
}
