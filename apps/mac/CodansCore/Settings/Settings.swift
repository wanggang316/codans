import Foundation
import os.log

/// Root Codable of `~/.config/codans/settings.json` (v3). Replaces the v2 shape whose
/// `repositories` dict held `RepositorySettings` with three GitHub-only fields — v3 widens
/// the per-Project slot to `ProjectSettings`, absorbing the editor / worktree-dir overrides
/// that used to live on `Project` in `catalog.json`. Single writer — `SettingsStore` — owns
/// the whole tree; readers that see a version outside `{2, 3}` back the file up and start
/// from defaults.
///
/// `Settings.init(from:)` is strict and accepts only v3 input. The v2→v3 transition (field
/// rename `repositories → projects`, type widening to `ProjectSettings`, catalog-side fold of
/// `defaultEditor` / `worktreesDirectory`) lives in `SettingsMigration.load`, where the
/// caller can inject a `catalogOverrides` closure that supplies the values stripped from the
/// companion catalog.json.
public nonisolated struct Settings: Equatable, Sendable {
  public static let currentVersion = 3

  public var version: Int
  public var general: GeneralSettings
  public var developer: DeveloperSettings
  public var worktree: WorktreeSettings
  public var projects: [ProjectID: ProjectSettings]
  /// v1.1 notifications system knobs. Additive in v1.1; pre-v1.1 settings.json files
  /// decode this field via `decodeIfPresent` and fall back to `.default`.
  public var notifications: NotificationsSettings
  /// Coding-agent launch presets. Additive: files written before the Agents
  /// pane shipped carry no `agents` key and decode to `.default`, which seeds
  /// one profile per built-in agent.
  public var agents: AgentSettings

  public init(
    version: Int = Settings.currentVersion,
    general: GeneralSettings = .default,
    developer: DeveloperSettings = .default,
    worktree: WorktreeSettings = .default,
    projects: [ProjectID: ProjectSettings] = [:],
    notifications: NotificationsSettings = .default,
    agents: AgentSettings = .default
  ) {
    self.version = version
    self.general = general
    self.developer = developer
    self.worktree = worktree
    self.projects = projects
    self.notifications = notifications
    self.agents = agents
  }

  public static let `default` = Settings()

  /// On-disk location: `<AppDirectories.configDirectory>/settings.json`
  /// (`-dev` suffixed for Debug builds — see `AppDirectories`).
  public static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    AppDirectories.configDirectory(home: home)
      .appendingPathComponent("settings.json", isDirectory: false)
  }

  /// Drop any `projects[id]` entry whose value is effectively empty, and collapse
  /// `projects[id].git` to `nil` when the nested subtree is itself empty. Called by
  /// `SettingsStore` before each save so `settings.json` does not retain `{}` placeholders
  /// or `"git": {}` stubs.
  public mutating func garbageCollect() {
    var cleaned: [ProjectID: ProjectSettings] = [:]
    cleaned.reserveCapacity(projects.count)
    for (pid, var entry) in projects {
      entry.collapseEmptyGit()
      if !entry.isEffectivelyEmpty {
        cleaned[pid] = entry
      }
    }
    projects = cleaned
  }

  /// Resets any stored editor ID that is not in the caller-provided built-in registry to
  /// `nil` on both `general.defaultEditorID` and `projects[pid].defaultEditor`. Run once at
  /// load so the in-memory `Settings` tree only references editors that the app currently
  /// knows about — stale IDs from the retired `customEditors` feature would otherwise
  /// linger in `settings.json` forever (the resolver is lenient and would silently fall
  /// back, but the stored value stays dead).
  ///
  /// `knownIDs` is passed in rather than imported so this helper stays in `CodansCore`
  /// without taking a dependency on the app-tier `EditorRegistry`. Idempotent — a second
  /// call on an already-cleaned `Settings` is a no-op and returns `false`.
  ///
  /// Returns `true` if any field was mutated so the caller can decide whether to persist.
  @discardableResult
  public mutating func garbageCollectEditors(knownIDs: Set<EditorID>) -> Bool {
    var mutated = false
    if let id = general.defaultEditorID, !knownIDs.contains(id) {
      general.defaultEditorID = nil
      mutated = true
    }
    if let id = general.defaultGitViewerID, !knownIDs.contains(id) {
      general.defaultGitViewerID = nil
      mutated = true
    }
    for (pid, var entry) in projects {
      var entryMutated = false
      if let id = entry.defaultEditor, !knownIDs.contains(id) {
        entry.defaultEditor = nil
        entryMutated = true
      }
      if entryMutated {
        projects[pid] = entry
        mutated = true
      }
    }
    return mutated
  }
}

extension Settings: Codable {
  public enum DecodingIssue: Error, Equatable {
    case unsupportedVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case version, general, developer, worktree, projects, notifications, agents
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    // v3-only on this path — `SettingsMigration.load` catches
    // `unsupportedVersion(2)` and runs the v2→v3 fold out-of-band.
    guard version == Settings.currentVersion else {
      throw DecodingIssue.unsupportedVersion(version)
    }
    self.version = version
    self.general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .default
    self.developer = try container.decodeIfPresent(DeveloperSettings.self, forKey: .developer) ?? .default
    self.worktree = try container.decodeIfPresent(WorktreeSettings.self, forKey: .worktree) ?? .default
    self.notifications =
      try container.decodeIfPresent(NotificationsSettings.self, forKey: .notifications) ?? .default
    self.agents = try container.decodeIfPresent(AgentSettings.self, forKey: .agents) ?? .default

    // `projects` is encoded as a JSON object keyed by the ProjectID UUID string so the file
    // is human-diffable and hand-editable. ProjectID itself is a Codable struct (encoded as
    // `{ "raw": "<uuid>" }` by default) which would force an array-of-pairs layout — we decode
    // the String-keyed form and convert. Unparseable keys are dropped with a log line so a
    // hand-edit typo doesn't abort the whole file load.
    let raw = try container.decodeIfPresent([String: ProjectSettings].self, forKey: .projects) ?? [:]
    var mapped: [ProjectID: ProjectSettings] = [:]
    mapped.reserveCapacity(raw.count)
    let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "settings")
    for (stringKey, value) in raw {
      if let uuid = UUID(uuidString: stringKey) {
        var entry = value
        // Hand-edits to settings.json can introduce duplicate script IDs. Replace
        // duplicates with fresh UUIDs at load so the per-script tab map and command
        // palette item identity stay well-defined.
        let replacements = entry.normalizeScriptIDs()
        for (old, new) in replacements {
          logger.warning(
            "Replaced duplicate ScriptDefinition id \(old.uuidString, privacy: .public) → \(new.uuidString, privacy: .public)"
          )
        }
        mapped[ProjectID(raw: uuid)] = entry
      } else {
        logger.warning("Dropping unparseable projects key: \(stringKey, privacy: .public)")
      }
    }
    self.projects = mapped
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(general, forKey: .general)
    try container.encode(developer, forKey: .developer)
    try container.encode(worktree, forKey: .worktree)
    try container.encode(notifications, forKey: .notifications)
    try container.encode(agents, forKey: .agents)
    var stringKeyed: [String: ProjectSettings] = [:]
    stringKeyed.reserveCapacity(projects.count)
    for (projectID, value) in projects {
      stringKeyed[projectID.raw.uuidString] = value
    }
    try container.encode(stringKeyed, forKey: .projects)
  }
}
