import Foundation

/// What the sheet's single Add field is being given, decided from the text
/// alone plus one existence check: a URL to clone, a path on disk, or a
/// search among the open projects.
nonisolated enum AddEntryKind: Equatable, Sendable {
  case empty
  /// Normalized: `host.tld/owner/repo` gains `https://`.
  case url(String)
  /// Tilde-expanded. `exists == false` for an absolute path with nothing
  /// behind it, so a typo is reported rather than searched.
  case path(String, exists: Bool)
  case search(String)
}

nonisolated enum AddEntryClassifier {
  /// Trims, then: URL forms first (a scheme, an scp-style `user@host:path`,
  /// or `host.tld/path`), then paths (`/`, `~`, `./`, `../`, or a slash
  /// with something at the expanded path), else a search query.
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
    return .search(text)
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

  /// Open projects matching `query`, best first: prefix beats substring
  /// beats subsequence, ties keep sidebar order. At most `limit`.
  static func rank<C: Collection>(
    _ candidates: C, query: String, limit: Int = 6, name: (C.Element) -> String, folder: (C.Element) -> String
  ) -> [C.Element] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }
    let scored = candidates.enumerated().compactMap { index, candidate -> (Int, Int, C.Element)? in
      let haystacks = [name(candidate).lowercased(), folder(candidate).lowercased()]
      let best = haystacks.compactMap { score(needle: needle, in: $0) }.min()
      return best.map { ($0, index, candidate) }
    }
    return
      scored
      .sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
      .prefix(limit)
      .map(\.2)
  }

  /// 0 prefix, 1 substring, 2 subsequence, nil no match.
  private static func score(needle: String, in haystack: String) -> Int? {
    if haystack.hasPrefix(needle) { return 0 }
    if haystack.contains(needle) { return 1 }
    var cursor = haystack.startIndex
    for character in needle {
      guard let found = haystack[cursor...].firstIndex(of: character) else { return nil }
      cursor = haystack.index(after: found)
    }
    return 2
  }
}
