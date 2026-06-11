import Foundation

/// Permissive Codable for the v2 `settings.json` shape. Retained as a migration-only type
/// so `SettingsMigration` can fold v2 `repositories[pid].{defaultMergeStrategy,
/// postMergeAction, githubDisabled}` into the v3 `projects[pid].git` subtree without
/// keeping the old `RepositorySettings` struct alive. Never written back to disk.
public nonisolated struct LegacyV2Settings: Decodable, Sendable {
  public let version: Int
  public let general: GeneralSettings?
  public let developer: DeveloperSettings?
  public let repositories: [String: LegacyV2RepositorySettings]

  public init(
    version: Int,
    general: GeneralSettings? = nil,
    developer: DeveloperSettings? = nil,
    repositories: [String: LegacyV2RepositorySettings] = [:]
  ) {
    self.version = version
    self.general = general
    self.developer = developer
    self.repositories = repositories
  }

  private enum CodingKeys: String, CodingKey {
    case version, general, developer, repositories
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try c.decode(Int.self, forKey: .version)
    self.general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general)
    self.developer = try c.decodeIfPresent(DeveloperSettings.self, forKey: .developer)
    self.repositories = try c.decodeIfPresent([String: LegacyV2RepositorySettings].self, forKey: .repositories) ?? [:]
  }
}

/// Minimal permissive decode of a v2 `repositories[pid]` value: the three GitHub-only
/// fields `RepositorySettings` carried. Every field is optional — the v2 encoder wrote
/// omit-when-default shapes, so the common case is `{}` for pids that had no overrides.
public nonisolated struct LegacyV2RepositorySettings: Decodable, Sendable {
  public let defaultMergeStrategy: MergeStrategy?
  public let postMergeAction: MergedWorktreeAction?
  public let githubDisabled: Bool

  public init(
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    githubDisabled: Bool = false
  ) {
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
    self.githubDisabled = githubDisabled
  }

  private enum CodingKeys: String, CodingKey {
    case defaultMergeStrategy, postMergeAction, githubDisabled
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.defaultMergeStrategy = try c.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try c.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
    self.githubDisabled = try c.decodeIfPresent(Bool.self, forKey: .githubDisabled) ?? false
  }
}
