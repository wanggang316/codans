import Foundation

/// What a parser needs from a project directory, read once up front so parsing
/// stays pure and the same parsers serve local and SSH projects alike.
public nonisolated struct ManifestRequest: Hashable, Sendable {
  /// Files whose contents are read (manifests: `package.json`, `Makefile`, …).
  public var contentPaths: [String]
  /// Files only probed for existence. Lockfiles live here — they identify the
  /// package manager but can be megabytes, so they never cross the wire.
  public var presencePaths: [String]

  public init(contentPaths: [String] = [], presencePaths: [String] = []) {
    self.contentPaths = contentPaths
    self.presencePaths = presencePaths
  }

  /// Order-preserving union, so a registry can ask the reader once for every
  /// parser. A path requested for its content also answers presence.
  public func merged(with other: ManifestRequest) -> ManifestRequest {
    let contents = Self.unique(contentPaths + other.contentPaths)
    let contentSet = Set(contents)
    let presence = Self.unique(presencePaths + other.presencePaths).filter { !contentSet.contains($0) }
    return ManifestRequest(contentPaths: contents, presencePaths: presence)
  }

  private static func unique(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }
}

/// The answer to a `ManifestRequest`: contents of the files that exist and are
/// readable, plus the set of paths that exist at all. Paths are relative to the
/// project directory, exactly as requested.
public nonisolated struct ManifestSnapshot: Equatable, Sendable {
  public var contents: [String: String]
  public var presentPaths: Set<String>

  public init(contents: [String: String] = [:], presentPaths: Set<String> = []) {
    self.contents = contents
    self.presentPaths = presentPaths.union(contents.keys)
  }

  public subscript(path: String) -> String? { contents[path] }

  public func exists(_ path: String) -> Bool { presentPaths.contains(path) }

  /// First path in `candidates` with readable contents, e.g. `Makefile` before
  /// `makefile`.
  public func firstContents(of candidates: [String]) -> (path: String, text: String)? {
    for path in candidates {
      if let text = contents[path] { return (path, text) }
    }
    return nil
  }
}
