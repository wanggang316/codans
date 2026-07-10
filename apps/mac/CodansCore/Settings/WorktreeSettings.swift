import Foundation

/// Auto-delete period for archived worktrees. Represents the number of days after
/// which a worktree archived via `codans worktree archive` is automatically deleted.
public nonisolated enum AutoDeletePeriod: Int, Equatable, Codable, Sendable, CaseIterable {
  case oneDay = 1
  case threeDays = 3
  case sevenDays = 7
  case fourteenDays = 14
  case thirtyDays = 30

  public var label: String {
    switch self {
    case .oneDay: return "1 day"
    case .threeDays: return "3 days"
    case .sevenDays: return "7 days"
    case .fourteenDays: return "14 days"
    case .thirtyDays: return "30 days"
    }
  }
}

/// `worktree` sub-tree of `settings.json` (v3). Global defaults for worktree creation
/// and management, used across all projects unless overridden per-project.
public nonisolated struct WorktreeSettings: Equatable, Codable, Sendable {
  /// Global default directory for cloning new worktrees. When `nil`, each project uses
  /// its own default (typically `~/.codans/repos/<projectName>/`). Projects can
  /// override this with their own `ProjectSettings.worktreesDirectory`.
  public var defaultWorktreesDirectory: String?
  /// Whether to fetch the remote before creating a new worktree. Default `true`.
  public var fetchRemoteOnCreate: Bool
  /// Whether to switch to a newly created worktree once it is ready. Default `true`.
  public var autoSwitchToNewWorktree: Bool
  /// Whether to copy `.gitignore`-listed files when creating a worktree. Default `false`.
  public var copyIgnoredOnCreate: Bool
  /// Whether to copy untracked files when creating a worktree. Default `false`.
  public var copyUntrackedOnCreate: Bool
  /// Whether to automatically delete archived worktrees after a period. Default `false`.
  public var autoDeleteArchived: Bool
  /// Period (in days) after which archived worktrees are auto-deleted. Ignored if
  /// `autoDeleteArchived` is false. Default `.sevenDays`.
  public var autoDeletePeriod: AutoDeletePeriod
  /// Whether to delete the remote branch when deleting a local worktree. Default `false`.
  public var deleteRemoteBranchWithWorktree: Bool

  public init(
    defaultWorktreesDirectory: String? = nil,
    fetchRemoteOnCreate: Bool = true,
    autoSwitchToNewWorktree: Bool = true,
    copyIgnoredOnCreate: Bool = false,
    copyUntrackedOnCreate: Bool = false,
    autoDeleteArchived: Bool = false,
    autoDeletePeriod: AutoDeletePeriod = .sevenDays,
    deleteRemoteBranchWithWorktree: Bool = false
  ) {
    self.defaultWorktreesDirectory = defaultWorktreesDirectory
    self.fetchRemoteOnCreate = fetchRemoteOnCreate
    self.autoSwitchToNewWorktree = autoSwitchToNewWorktree
    self.copyIgnoredOnCreate = copyIgnoredOnCreate
    self.copyUntrackedOnCreate = copyUntrackedOnCreate
    self.autoDeleteArchived = autoDeleteArchived
    self.autoDeletePeriod = autoDeletePeriod
    self.deleteRemoteBranchWithWorktree = deleteRemoteBranchWithWorktree
  }

  public static let `default` = WorktreeSettings()

  private enum CodingKeys: String, CodingKey {
    case defaultWorktreesDirectory, fetchRemoteOnCreate, autoSwitchToNewWorktree, copyIgnoredOnCreate
    case copyUntrackedOnCreate, autoDeleteArchived, autoDeletePeriod, deleteRemoteBranchWithWorktree
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.defaultWorktreesDirectory = try container.decodeIfPresent(String.self, forKey: .defaultWorktreesDirectory)
    self.fetchRemoteOnCreate = try container.decodeIfPresent(Bool.self, forKey: .fetchRemoteOnCreate) ?? true
    self.autoSwitchToNewWorktree = try container.decodeIfPresent(Bool.self, forKey: .autoSwitchToNewWorktree) ?? true
    self.copyIgnoredOnCreate = try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnCreate) ?? false
    self.copyUntrackedOnCreate = try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnCreate) ?? false
    self.autoDeleteArchived = try container.decodeIfPresent(Bool.self, forKey: .autoDeleteArchived) ?? false
    self.autoDeletePeriod =
      try container.decodeIfPresent(AutoDeletePeriod.self, forKey: .autoDeletePeriod) ?? .sevenDays
    self.deleteRemoteBranchWithWorktree =
      try container.decodeIfPresent(Bool.self, forKey: .deleteRemoteBranchWithWorktree) ?? false
    // A legacy `branchConflictResolution` key from the removed resolution
    // picker is simply ignored (keyed decode skips unknown keys).
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(defaultWorktreesDirectory, forKey: .defaultWorktreesDirectory)
    if fetchRemoteOnCreate != true {
      try container.encode(fetchRemoteOnCreate, forKey: .fetchRemoteOnCreate)
    }
    if autoSwitchToNewWorktree != true {
      try container.encode(autoSwitchToNewWorktree, forKey: .autoSwitchToNewWorktree)
    }
    if copyIgnoredOnCreate != false {
      try container.encode(copyIgnoredOnCreate, forKey: .copyIgnoredOnCreate)
    }
    if copyUntrackedOnCreate != false {
      try container.encode(copyUntrackedOnCreate, forKey: .copyUntrackedOnCreate)
    }
    if autoDeleteArchived != false {
      try container.encode(autoDeleteArchived, forKey: .autoDeleteArchived)
    }
    if autoDeletePeriod != .sevenDays {
      try container.encode(autoDeletePeriod, forKey: .autoDeletePeriod)
    }
    if deleteRemoteBranchWithWorktree != false {
      try container.encode(deleteRemoteBranchWithWorktree, forKey: .deleteRemoteBranchWithWorktree)
    }
  }

  // MARK: - Base directory resolution

  /// Bottom-of-the-chain default when neither the per-project override nor
  /// the global `defaultWorktreesDirectory` has been set. The single source
  /// of truth for the `~/.codans/repos` literal — every UI surface and
  /// IPC path that needs to display or compute a worktree base directory
  /// resolves through `resolveBaseDirectory` (or `resolveGlobalBaseDirectory`),
  /// not by re-deriving this path.
  public static func systemFallbackBaseDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home.appending(path: ".codans/repos", directoryHint: .isDirectory)
  }

  /// Resolves the worktree base directory for a given project, walking the
  /// fallback chain: per-project override → global default → system fallback.
  ///
  /// The per-project override is used verbatim (the user picked a specific
  /// directory). The global default and system fallback are treated as shared
  /// bases under which each project's worktrees live in its own subdirectory,
  /// so `projectName` is appended in those cases.
  public func resolveBaseDirectory(
    forProjectName projectName: String,
    projectOverride: String?,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    if let override = projectOverride, !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    if let global = defaultWorktreesDirectory, !global.isEmpty {
      return URL(fileURLWithPath: global)
        .appending(path: projectName, directoryHint: .isDirectory)
    }
    return Self.systemFallbackBaseDirectory(home: home)
      .appending(path: projectName, directoryHint: .isDirectory)
  }

  /// Resolves the global base directory (without per-project appending) for
  /// display when editing global settings — global default if set, else
  /// system fallback. Use this for the Settings → Worktree pane placeholder.
  public func resolveGlobalBaseDirectory(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    if let global = defaultWorktreesDirectory, !global.isEmpty {
      return URL(fileURLWithPath: global)
    }
    return Self.systemFallbackBaseDirectory(home: home)
  }
}
