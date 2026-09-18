import Foundation

public nonisolated enum GitComparisonScope: String, CaseIterable, Sendable, Equatable {
  case all, staged, unstaged, outgoing
}

public nonisolated struct GitComparisonFile: Identifiable, Sendable, Equatable {
  public var id: String { path }
  public var path: String
  public var oldPath: String?
  public var status: String
  public var additions: Int?
  public var deletions: Int?
  public var isBinary: Bool
  public var oldObject: String
  public var newObject: String
  public var oldMode: String
  public var newMode: String

  public init(
    path: String, oldPath: String? = nil, status: String, additions: Int? = nil,
    deletions: Int? = nil, isBinary: Bool = false, oldObject: String = "",
    newObject: String = "", oldMode: String = "000000", newMode: String = "100644"
  ) {
    self.path = path
    self.oldPath = oldPath
    self.status = status
    self.additions = additions
    self.deletions = deletions
    self.isBinary = isBinary
    self.oldObject = oldObject
    self.newObject = newObject
    self.oldMode = oldMode
    self.newMode = newMode
  }
}

public nonisolated struct GitComparisonSnapshot: Sendable, Equatable {
  public var id: String
  public var scope: GitComparisonScope
  public var baseLabel: String
  public var files: [GitComparisonFile]
  public var repositoryPath: String

  public init(
    id: String = UUID().uuidString, scope: GitComparisonScope, baseLabel: String,
    files: [GitComparisonFile], repositoryPath: String = ""
  ) {
    self.id = id
    self.scope = scope
    self.baseLabel = baseLabel
    self.files = files
    self.repositoryPath = repositoryPath
  }
}

nonisolated extension GitComparisonSnapshot {
  /// Line counts summed across every file. Files without counts (binary, unreadable, oversized)
  /// are skipped. The single definition of a comparison's totals, so every surface agrees.
  public var lineTotals: LocalDiffStats {
    LocalDiffStats(
      additions: files.compactMap(\.additions).reduce(0, +),
      deletions: files.compactMap(\.deletions).reduce(0, +))
  }
}

public nonisolated struct GitComparisonContent: Sendable, Equatable {
  public var oldText: String
  public var newText: String
  public var notice: String?

  public init(oldText: String = "", newText: String = "", notice: String? = nil) {
    self.oldText = oldText
    self.newText = newText
    self.notice = notice
  }
}
