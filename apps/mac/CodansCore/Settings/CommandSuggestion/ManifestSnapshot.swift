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

/// How far below the project directory a reader looks for manifests. Shared
/// by the local and SSH readers so both walk exactly the same tree.
public nonisolated struct ManifestScope: Hashable, Sendable {
  /// Directory levels below the root that are searched: 3 reaches
  /// `apps/web/client/package.json`.
  public var maxDepth: Int
  /// Directory names never descended into — dependency caches and build
  /// output hold thousands of third-party manifests nobody runs.
  public var ignoredDirectoryNames: Set<String>

  public init(maxDepth: Int, ignoredDirectoryNames: Set<String>) {
    self.maxDepth = maxDepth
    self.ignoredDirectoryNames = ignoredDirectoryNames
  }

  public static let standard = ManifestScope(
    maxDepth: 3,
    ignoredDirectoryNames: [
      "node_modules", "bower_components", "vendor", "Pods", "Carthage",
      "dist", "build", "out", "target", "coverage", "tmp", "DerivedData",
      "venv", "env", "__pycache__", "site-packages",
    ]
  )

  /// Hidden directories (`.git`, `.next`, `.venv`, `.build`) are skipped too;
  /// hidden *files* at a searched level (`.justfile`, `.mise.toml`) are not.
  public func shouldDescend(into directoryName: String) -> Bool {
    !directoryName.hasPrefix(".") && !ignoredDirectoryNames.contains(directoryName)
  }
}

/// The answer to a `ManifestRequest`: contents of the files that exist and are
/// readable, plus the set of paths that exist at all. Paths are relative to the
/// directory the parser looks at.
///
/// A reader returns one snapshot for the whole tree (`packages/web/package.json`
/// keys); the registry then hands each parser a per-directory view whose
/// `ancestors` expose enclosing directories — a workspace member inherits its
/// package manager from the root's lockfile.
public nonisolated struct ManifestSnapshot: Equatable, Sendable {
  public var contents: [String: String]
  public var presentPaths: Set<String>
  /// Views of the enclosing directories, nearest first. Empty at the root.
  public var ancestors: [ManifestSnapshot]

  public init(contents: [String: String] = [:], presentPaths: Set<String> = [], ancestors: [ManifestSnapshot] = []) {
    self.contents = contents
    self.presentPaths = presentPaths.union(contents.keys)
    self.ancestors = ancestors
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

  /// Directories (relative, `""` for the root) holding at least one file,
  /// root first then lexicographic so `packages/a` precedes `packages/b`.
  public var directories: [String] {
    let dirs = Set(presentPaths.map(Self.directory(of:)))
    return dirs.sorted { lhs, rhs in
      if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty }
      return lhs < rhs
    }
  }

  /// The files directly inside `directory`, keyed by bare file name, with the
  /// enclosing directories as `ancestors`.
  public func scoped(to directory: String) -> ManifestSnapshot {
    var ancestors: [ManifestSnapshot] = []
    var parent = directory
    while !parent.isEmpty {
      parent = Self.directory(of: parent)
      ancestors.append(level(parent))
    }
    var view = level(directory)
    view.ancestors = ancestors
    return view
  }

  private func level(_ directory: String) -> ManifestSnapshot {
    let prefix = directory.isEmpty ? "" : directory + "/"
    func direct(_ path: String) -> String? {
      guard path.hasPrefix(prefix) else { return nil }
      let name = String(path.dropFirst(prefix.count))
      return name.contains("/") ? nil : name
    }
    var contents: [String: String] = [:]
    for (path, text) in self.contents {
      if let name = direct(path) { contents[name] = text }
    }
    return ManifestSnapshot(contents: contents, presentPaths: Set(presentPaths.compactMap(direct)))
  }

  static func directory(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }
}
