import Foundation

/// A `SkillFileSystem` for another host: it answers from reads made before
/// and records each read it cannot answer. A reader runs the resolver and
/// the scanner against it, fetches the recorded reads in one batch, and
/// runs them again, until nothing is missing. Each read the resolver makes
/// depends only on earlier answers, so the last run reads what the agent
/// on that host reads.
///
/// An unanswered read gives "missing" for this run. To save rounds, a
/// missing `.git` entry also asks for the `.git` entry of every parent (the
/// repository walk), and a directory answer carries the `SKILL.md` of each
/// child (the scan).
public nonisolated final class SkillFileSnapshot: SkillFileSystem, @unchecked Sendable {
  /// One read on the host. Paths are absolute, without a trailing `/`.
  public enum Request: Hashable, Sendable {
    /// The file at the path: its bytes, or whether something is there.
    case file(String)
    /// The names in the directory at the path, with the `SKILL.md` of each.
    case directory(String)
    /// The physical path of the directory at the path.
    case realPath(String)
  }

  public enum FileAnswer: Equatable, Sendable {
    case missing
    /// Something is there, but not a file codans can read: a directory, an
    /// unreadable file, or a file over the size limit.
    case unreadable
    case data(Data)
  }

  /// One entry of a directory answer.
  public struct Child: Equatable, Sendable {
    public var name: String
    /// The child's `SKILL.md`, `nil` when it has none.
    public var skill: Data?

    public init(name: String, skill: Data? = nil) {
      self.name = name
      self.skill = skill
    }
  }

  private let lock = NSLock()
  private var files: [String: FileAnswer] = [:]
  private var directories: [String: [String]?] = [:]
  private var realPaths: [String: String?] = [:]
  private var misses: [Request] = []
  private var missSet: Set<Request> = []

  public init() {}

  // MARK: - Answers

  public func setFile(_ path: String, _ answer: FileAnswer) {
    lock.withLock { files[Self.key(path)] = answer }
  }

  /// `children` is `nil` when no readable directory is at `path`. Each
  /// child's `SKILL.md` becomes a file answer, `missing` when it has none.
  public func setDirectory(_ path: String, _ children: [Child]?) {
    let path = Self.key(path)
    lock.withLock {
      directories[path] = children.map { $0.map(\.name) }
      for child in children ?? [] {
        files[Self.child(path, child.name) + "/SKILL.md"] = child.skill.map(FileAnswer.data) ?? .missing
      }
    }
  }

  public func setRealPath(_ path: String, _ answer: String?) {
    lock.withLock { realPaths[Self.key(path)] = .some(answer) }
  }

  /// The reads asked for since the last call, in the order they were
  /// asked, without duplicates.
  public func takeMisses() -> [Request] {
    lock.withLock {
      defer {
        misses = []
        missSet = []
      }
      return misses
    }
  }

  // MARK: - SkillFileSystem

  public func contents(atPath path: String) -> Data? {
    let path = Self.key(path)
    return lock.withLock {
      switch files[path] {
      case .data(let data): return data
      case .missing, .unreadable: return nil
      case nil:
        recordFileMiss(path)
        return nil
      }
    }
  }

  public func fileExists(atPath path: String) -> Bool {
    let path = Self.key(path)
    return lock.withLock {
      if let answer = files[path] { return answer != .missing }
      if let listing = directories[path] { return listing != nil }
      recordFileMiss(path)
      return false
    }
  }

  public func contentsOfDirectory(atPath path: String) -> [String]? {
    let path = Self.key(path)
    return lock.withLock {
      if let listing = directories[path] { return listing }
      record(.directory(path))
      return nil
    }
  }

  public func realPath(_ path: String) -> String? {
    let path = Self.key(path)
    return lock.withLock {
      if let answer = realPaths[path] { return answer }
      record(.realPath(path))
      return nil
    }
  }

  // MARK: - Private (lock held)

  private func recordFileMiss(_ path: String) {
    record(.file(path))
    guard (path as NSString).lastPathComponent == ".git" else { return }
    var directory = (path as NSString).deletingLastPathComponent
    while directory != "/", !directory.isEmpty {
      directory = (directory as NSString).deletingLastPathComponent
      let entry = Self.child(directory, ".git")
      if files[entry] == nil { record(.file(entry)) }
    }
  }

  private func record(_ request: Request) {
    if missSet.insert(request).inserted { misses.append(request) }
  }

  /// `path` without a trailing `/`, so a directory URL's path and a file
  /// URL's path name the same entry.
  static func key(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  private static func child(_ directory: String, _ name: String) -> String {
    directory == "/" ? "/" + name : directory + "/" + name
  }
}
