import CryptoKit
import Foundation

/// Where a workflow file came from. Later scopes shadow earlier ones by id.
public nonisolated enum WorkflowScope: String, Codable, Sendable, CaseIterable, Comparable {
  /// Shipped inside the app bundle (`Resources/workflows/`).
  case bundle
  /// `~/.codans/workflows/`.
  case user
  /// `<repo root>/.codans/workflows/`, committed with the branch.
  case repo

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.precedence < rhs.precedence
  }

  private var precedence: Int {
    switch self {
    case .bundle: return 0
    case .user: return 1
    case .repo: return 2
    }
  }
}

/// One discovered `<id>.workflow.yaml`, parsed and validated. The raw text
/// and its hash ride along so a run can copy the exact definition it
/// started from and a trust grant can be checked against the bytes.
public nonisolated struct WorkflowCatalogEntry: Equatable, Sendable {
  public var id: String
  public var scope: WorkflowScope
  public var path: String
  public var yaml: String
  public var sha256: String
  public var definition: WorkflowDefinition?
  public var diagnostics: [WorkflowDiagnostic]

  public init(
    id: String,
    scope: WorkflowScope,
    path: String,
    yaml: String,
    sha256: String,
    definition: WorkflowDefinition?,
    diagnostics: [WorkflowDiagnostic]
  ) {
    self.id = id
    self.scope = scope
    self.path = path
    self.yaml = yaml
    self.sha256 = sha256
    self.definition = definition
    self.diagnostics = diagnostics
  }

  public var isValid: Bool { definition != nil && !diagnostics.hasErrors }
  public var name: String { definition?.name ?? id }
  /// Only repository files that execute shell commands need the user's
  /// one-time trust; bundle and user scopes are the user's own.
  public var requiresTrust: Bool { scope == .repo && (definition?.executesCommands ?? false) }
}

/// Scans the three workflow directories and resolves shadowing. Pure
/// filesystem reads, no caching: definitions are few and small, and a
/// rescan per `list` / `run` is cheaper than getting invalidation wrong.
public nonisolated struct WorkflowDiscovery: Sendable {
  public static let repositoryDirectoryName = "workflows"

  public var bundleDirectory: URL?
  public var userDirectory: URL

  public init(bundleDirectory: URL?, userDirectory: URL) {
    self.bundleDirectory = bundleDirectory
    self.userDirectory = userDirectory
  }

  /// `<worktree>/.codans/workflows`.
  public static func repositoryDirectory(worktreeRoot: URL) -> URL {
    worktreeRoot
      .appendingPathComponent(HandoffLayout.stateDirectoryName, isDirectory: true)
      .appendingPathComponent(repositoryDirectoryName, isDirectory: true)
  }

  /// Every entry, one per id, the highest-precedence scope winning; sorted
  /// by id for stable listings.
  public func catalog(worktreeRoot: URL?) -> [WorkflowCatalogEntry] {
    var byID: [String: WorkflowCatalogEntry] = [:]
    for entry in scanAll(worktreeRoot: worktreeRoot) {
      if let existing = byID[entry.id], existing.scope > entry.scope { continue }
      byID[entry.id] = entry
    }
    return byID.values.sorted { $0.id < $1.id }
  }

  /// Every file in every scope, shadowed ones included, for the Settings
  /// list that shows what is hidden by what.
  public func scanAll(worktreeRoot: URL?) -> [WorkflowCatalogEntry] {
    var entries: [WorkflowCatalogEntry] = []
    if let bundleDirectory {
      entries += Self.scan(directory: bundleDirectory, scope: .bundle)
    }
    entries += Self.scan(directory: userDirectory, scope: .user)
    if let worktreeRoot {
      entries += Self.scan(directory: Self.repositoryDirectory(worktreeRoot: worktreeRoot), scope: .repo)
    }
    return entries
  }

  /// Resolves `reference` as an id first, then as a unique display name
  /// (case-insensitive). `nil` when nothing matches or a name is ambiguous.
  public func resolve(_ reference: String, worktreeRoot: URL?) -> WorkflowCatalogEntry? {
    let entries = catalog(worktreeRoot: worktreeRoot)
    if let exact = entries.first(where: { $0.id == reference }) { return exact }
    let byName = entries.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
    return byName.count == 1 ? byName[0] : nil
  }

  public static func scan(directory: URL, scope: WorkflowScope) -> [WorkflowCatalogEntry] {
    let fileManager = FileManager.default
    guard
      let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    else { return [] }
    return names.sorted().compactMap { name in
      guard let id = WorkflowDocumentParser.workflowID(fromFileName: name) else { return nil }
      let url = directory.appendingPathComponent(name, isDirectory: false)
      return load(url: url, id: id, scope: scope)
    }
  }

  public static func load(url: URL, id: String, scope: WorkflowScope) -> WorkflowCatalogEntry? {
    guard let data = try? Data(contentsOf: url), let yaml = String(data: data, encoding: .utf8) else { return nil }
    let parsed = WorkflowDocumentParser.parse(yaml: yaml, id: id)
    var diagnostics = parsed.diagnostics
    if let definition = parsed.definition {
      diagnostics += WorkflowValidator.validate(definition)
    }
    return WorkflowCatalogEntry(
      id: id,
      scope: scope,
      path: url.path(percentEncoded: false),
      yaml: yaml,
      sha256: sha256(of: data),
      definition: diagnostics.hasErrors ? nil : parsed.definition,
      diagnostics: diagnostics
    )
  }

  public static func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
