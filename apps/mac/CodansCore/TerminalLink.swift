import Foundation

/// A link the user activated in terminal output (⌘-click on a URL or path
/// matched by libghostty's link regex, or an OSC 8 hyperlink), classified
/// into something the app can open.
///
/// libghostty hands the matched text over verbatim: scheme URLs, but also
/// bare paths such as `src/App.swift:42:7` or `~/notes.md`. It only
/// resolves a relative path against the pane's pwd when the whole string
/// names an existing file, so the `:line[:column]` suffix agents print is
/// stripped and resolved here.
public nonisolated enum TerminalLink: Sendable, Equatable {
  /// Anything with a URL scheme other than `file:` — handed to LaunchServices.
  case external(URL)
  case file(TerminalFileLocation)

  /// Opaque schemes (no `//` authority) that libghostty's matcher accepts.
  /// Any other `word:` prefix is treated as part of a path, so `App.swift:12`
  /// is not mistaken for a URL with scheme `App.swift`.
  private static let opaqueSchemes: Set<String> = ["mailto", "tel", "news", "magnet", "ssh", "file"]

  /// Classifies `raw`.
  ///
  /// - Parameters:
  ///   - baseDirectory: directory relative paths resolve against (the pane's
  ///     pwd); `nil` makes relative paths unresolvable.
  ///   - homeDirectory: expansion target for `~` and `$HOME`; `nil` (a
  ///     remote host whose home is unknown) makes such paths unresolvable.
  ///   - fileExists: whether an absolute path exists. Decides whether a
  ///     trailing `:N` is a line number or part of the filename; pass `nil`
  ///     when the filesystem is not local (remote projects), which always
  ///     treats the suffix as a location.
  /// - Returns: `nil` when `raw` is empty or its path cannot be made absolute.
  public static func parse(
    _ raw: String,
    baseDirectory: String?,
    homeDirectory: String?,
    fileExists: ((String) -> Bool)? = nil
  ) -> TerminalLink? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains("\0") else { return nil }

    if let scheme = scheme(of: text) {
      guard let url = URL(string: text) else { return nil }
      guard scheme == "file" else { return .external(url) }
      guard !url.path.isEmpty else { return nil }
      return fileLink(url.path, baseDirectory: nil, homeDirectory: homeDirectory, fileExists: fileExists)
    }
    return fileLink(text, baseDirectory: baseDirectory, homeDirectory: homeDirectory, fileExists: fileExists)
  }

  private static func scheme(of text: String) -> String? {
    guard let colon = text.firstIndex(of: ":") else { return nil }
    let candidate = text[..<colon]
    guard let first = candidate.first, first.isASCII, first.isLetter,
      candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
    else { return nil }
    let scheme = candidate.lowercased()
    let rest = text[text.index(after: colon)...]
    return rest.hasPrefix("//") || opaqueSchemes.contains(scheme) ? scheme : nil
  }

  private static func fileLink(
    _ text: String,
    baseDirectory: String?,
    homeDirectory: String?,
    fileExists: ((String) -> Bool)?
  ) -> TerminalLink? {
    let resolved = absolutePath(text, baseDirectory: baseDirectory, homeDirectory: homeDirectory)
    // A filename may legitimately end in `:N`; only strip when the full
    // string does not already name a file.
    if let resolved, fileExists?(resolved) == true {
      return .file(TerminalFileLocation(path: resolved))
    }
    if let (path, line, column) = splitLocation(text),
      let base = absolutePath(path, baseDirectory: baseDirectory, homeDirectory: homeDirectory)
    {
      return .file(TerminalFileLocation(path: base, line: line, column: column))
    }
    return resolved.map { .file(TerminalFileLocation(path: $0)) }
  }

  /// Splits `path:line` / `path:line:column`. Zero is not a valid line.
  private static func splitLocation(_ text: String) -> (String, Int, Int?)? {
    var parts = text.split(separator: ":", omittingEmptySubsequences: false)
    var numbers: [Int] = []
    while numbers.count < 2, parts.count > 1, let last = parts.last,
      !last.isEmpty, last.allSatisfy(\.isASCII), let value = Int(last), value > 0
    {
      numbers.insert(value, at: 0)
      parts.removeLast()
    }
    guard let line = numbers.first else { return nil }
    let path = parts.joined(separator: ":")
    guard !path.isEmpty else { return nil }
    return (path, line, numbers.count > 1 ? numbers[1] : nil)
  }

  private static func absolutePath(
    _ path: String, baseDirectory: String?, homeDirectory: String?
  ) -> String? {
    var path = path
    for prefix in ["~", "$HOME"] where path == prefix || path.hasPrefix(prefix + "/") {
      guard let homeDirectory else { return nil }
      path = homeDirectory + path.dropFirst(prefix.count)
      break
    }
    if !path.hasPrefix("/") {
      guard let baseDirectory, baseDirectory.hasPrefix("/") else { return nil }
      path = baseDirectory + "/" + path
    }
    return URL(fileURLWithPath: path).standardized.path
  }
}

/// A resolved file target: absolute path plus the optional 1-based location
/// parsed from a `:line[:column]` suffix.
public nonisolated struct TerminalFileLocation: Sendable, Equatable {
  public var path: String
  public var line: Int?
  public var column: Int?

  public init(path: String, line: Int? = nil, column: Int? = nil) {
    self.path = path
    self.line = line
    self.column = column
  }
}
