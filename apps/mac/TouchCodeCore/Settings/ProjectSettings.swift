import Foundation

/// `projects[<ProjectID>]` value in `settings.json` (v3). Replaces the v2
/// `RepositorySettings`. Universal top-level fields apply to both `git_repo`
/// and `dir` Projects; the `git: GitProjectSettings?` nested subtree
/// carries git-kind-only overrides and is left `nil` for `dir`
/// Projects or when the user has no Git / GitHub overrides set.
///
/// Every Optional field means "inherit the global default" when `nil`. The
/// garbage collector before save drops empty `ProjectSettings{}` entries
/// from the outer `Settings.projects` dict and collapses
/// `git: GitProjectSettings()` to `nil` so `settings.json` never
/// accumulates useless `{}` objects.
public nonisolated struct ProjectSettings: Equatable, Codable, Sendable {
  /// Per-Project override of the global default editor. `nil` = inherit
  /// `GeneralSettings.defaultEditorID`. Moved off `Project` in catalog.json
  /// during the v2 → v3 settings migration.
  public var defaultEditor: EditorID?

  /// Per-Project override of the Git Viewer choice driving ⌘⌥G. `nil` =
  /// inherit `GeneralSettings.defaultGitViewerID`. The enum carries the
  /// override-to-`.builtin` case so a Project can opt back into the in-app
  /// overlay even when the global default points at an external client.
  public var defaultGitViewer: ProjectGitViewerPreference?

  /// Per-Project override of the global default worktree base directory.
  /// `nil` = inherit. No-op on `dir` Projects (kept for data-model
  /// uniformity; a future `git init` upgrade would pick it up for free).
  public var worktreesDirectory: String?

  /// Environment variables injected into new panes opened under this
  /// Project. Empty by default. Reserved slot — the Environment sub-pane
  /// fills in the editing UI in a follow-up wave.
  public var envVars: [String: String]

  /// User-defined scripts surfaced in the Scripts sub-pane and command
  /// palette. Empty by default. Reserved slot — `ScriptDefinition` is a
  /// placeholder pending the Scripts sub-pane follow-up wave.
  public var scripts: [ScriptDefinition]

  /// Git-kind-only subtree. `nil` on `dir` Projects or whenever
  /// every git-subtree field is at its default. Collapsed to `nil` by
  /// `isEffectivelyEmpty`-checking garbage collection before save.
  public var git: GitProjectSettings?

  public init(
    defaultEditor: EditorID? = nil,
    defaultGitViewer: ProjectGitViewerPreference? = nil,
    worktreesDirectory: String? = nil,
    envVars: [String: String] = [:],
    scripts: [ScriptDefinition] = [],
    git: GitProjectSettings? = nil
  ) {
    self.defaultEditor = defaultEditor
    self.defaultGitViewer = defaultGitViewer
    self.worktreesDirectory = worktreesDirectory
    self.envVars = envVars
    self.scripts = scripts
    self.git = git
  }

  /// True when every field is at its default AND `git` is either nil or
  /// itself effectively empty. The outer `Settings.garbageCollect()`
  /// drops `projects[pid]` entries whose value answers `true` here.
  public var isEffectivelyEmpty: Bool {
    defaultEditor == nil
      && defaultGitViewer == nil
      && worktreesDirectory == nil
      && envVars.isEmpty
      && scripts.isEmpty
      && (git?.isEffectivelyEmpty ?? true)
  }

  /// Mutating helper for garbage collection: collapse `git` to `nil`
  /// when the nested subtree is effectively empty. Called by
  /// `Settings.garbageCollect()` per entry before save so empty git
  /// subtrees do not persist as `"git": {}` on disk.
  public mutating func collapseEmptyGit() {
    if let git, git.isEffectivelyEmpty {
      self.git = nil
    }
  }

  /// Replace any duplicate `id` in `scripts` with a fresh UUID so the
  /// per-script tab map and Command Palette item identity stay
  /// well-defined. Returns the list of (oldID, newID) replacements so
  /// callers can log them. `settings.json` is hand-editable; a user who
  /// duplicates a script entry would otherwise break script→tab routing
  /// silently. Idempotent.
  public mutating func normalizeScriptIDs() -> [(old: UUID, new: UUID)] {
    var seen: Set<UUID> = []
    var replacements: [(old: UUID, new: UUID)] = []
    for index in scripts.indices {
      let id = scripts[index].id
      if seen.insert(id).inserted {
        continue
      }
      let fresh = UUID()
      replacements.append((old: id, new: fresh))
      scripts[index].id = fresh
      seen.insert(fresh)
    }
    return replacements
  }

  private enum CodingKeys: String, CodingKey {
    case defaultEditor
    case defaultGitViewer
    case worktreesDirectory
    case envVars
    case scripts
    case git
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.defaultEditor = try c.decodeIfPresent(EditorID.self, forKey: .defaultEditor)
    self.defaultGitViewer = try c.decodeIfPresent(
      ProjectGitViewerPreference.self, forKey: .defaultGitViewer
    )
    self.worktreesDirectory = try c.decodeIfPresent(String.self, forKey: .worktreesDirectory)
    self.envVars = try c.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
    self.scripts = try c.decodeIfPresent([ScriptDefinition].self, forKey: .scripts) ?? []
    self.git = try c.decodeIfPresent(GitProjectSettings.self, forKey: .git)
  }

  /// Omit-when-default encoding. Empty collections / nil Optionals / an
  /// effectively-empty `git` do not appear in the JSON object.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(defaultEditor, forKey: .defaultEditor)
    try c.encodeIfPresent(defaultGitViewer, forKey: .defaultGitViewer)
    try c.encodeIfPresent(worktreesDirectory, forKey: .worktreesDirectory)
    if !envVars.isEmpty {
      try c.encode(envVars, forKey: .envVars)
    }
    if !scripts.isEmpty {
      try c.encode(scripts, forKey: .scripts)
    }
    if let git, !git.isEffectivelyEmpty {
      try c.encode(git, forKey: .git)
    }
  }
}
