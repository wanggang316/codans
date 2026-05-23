import Foundation

/// Git-kind-only per-Project preferences nested under
/// `ProjectSettings.git`. Present when the user has at least one Git /
/// GitHub override set on a `git_repo` Project; cleared to `nil` by the
/// garbage collector before save whenever every field is at its default.
///
/// Most fields are `Optional<T>`: `nil` means "inherit the global default"
/// (from `GeneralSettings`). `githubDisabled` is a plain `Bool` defaulting
/// to `false` — the common case is "GitHub integration on" and the
/// omit-when-default encoder leaves it off disk unless the user flipped it.
public nonisolated struct GitProjectSettings: Equatable, Codable, Sendable {
  public var worktreeBaseRef: String?
  public var copyIgnoredOnWorktreeCreate: Bool?
  public var copyUntrackedOnWorktreeCreate: Bool?
  public var fetchRemoteOnWorktreeCreate: Bool?
  public var defaultMergeStrategy: MergeStrategy?
  public var postMergeAction: MergedWorktreeAction?
  public var githubDisabled: Bool

  /// Script run as the `initialCommand` of the worktree's first
  /// auto-opened pane right after `git worktree add` completes.
  /// `nil` means no script. The user sees realtime output in that
  /// pane; there is no headless capture or toast.
  public var createScript: ScriptDefinition?

  /// Script run before a worktree is archived. Materializes in a fresh
  /// tab on the worktree as the new pane's `initialCommand`. The
  /// archived flag flips only after that pane's child process exits;
  /// users typically end the script with `exit` or write a one-shot
  /// command so the pty terminates cleanly.
  public var archiveScript: ScriptDefinition?

  /// Script run before a worktree is removed from the sidebar list
  /// (i.e. when the worktree is *not* archived yet). Same materialization
  /// as `archiveScript`; the worktree teardown waits for the pane's
  /// child to exit so the script can never be killed mid-run. Removal
  /// from the archived list skips this script entirely.
  public var deleteScript: ScriptDefinition?

  public init(
    worktreeBaseRef: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    fetchRemoteOnWorktreeCreate: Bool? = nil,
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    githubDisabled: Bool = false,
    createScript: ScriptDefinition? = nil,
    archiveScript: ScriptDefinition? = nil,
    deleteScript: ScriptDefinition? = nil
  ) {
    self.worktreeBaseRef = worktreeBaseRef
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.fetchRemoteOnWorktreeCreate = fetchRemoteOnWorktreeCreate
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
    self.githubDisabled = githubDisabled
    self.createScript = createScript
    self.archiveScript = archiveScript
    self.deleteScript = deleteScript
  }

  /// True when every field is at its default. `ProjectSettings` clears
  /// its `git` child to `nil` when this is true before save, so
  /// `settings.json` does not accumulate useless `"git": {}` objects.
  /// A lifecycle script counts as empty when nil **or** its `command`
  /// is empty — the encoder skips both, so this stays symmetric.
  public var isEffectivelyEmpty: Bool {
    worktreeBaseRef == nil
      && copyIgnoredOnWorktreeCreate == nil
      && copyUntrackedOnWorktreeCreate == nil
      && fetchRemoteOnWorktreeCreate == nil
      && defaultMergeStrategy == nil
      && postMergeAction == nil
      && githubDisabled == false
      && (createScript?.command.isEmpty ?? true)
      && (archiveScript?.command.isEmpty ?? true)
      && (deleteScript?.command.isEmpty ?? true)
  }

  private enum CodingKeys: String, CodingKey {
    case worktreeBaseRef
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case fetchRemoteOnWorktreeCreate
    case defaultMergeStrategy
    case postMergeAction
    case githubDisabled
    case createScript
    case archiveScript
    case deleteScript
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.worktreeBaseRef = try c.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    self.copyIgnoredOnWorktreeCreate = try c.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
    self.copyUntrackedOnWorktreeCreate = try c.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
    self.fetchRemoteOnWorktreeCreate = try c.decodeIfPresent(Bool.self, forKey: .fetchRemoteOnWorktreeCreate)
    self.defaultMergeStrategy = try c.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try c.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
    self.githubDisabled = try c.decodeIfPresent(Bool.self, forKey: .githubDisabled) ?? false
    self.createScript = try c.decodeIfPresent(ScriptDefinition.self, forKey: .createScript)
    self.archiveScript = try c.decodeIfPresent(ScriptDefinition.self, forKey: .archiveScript)
    self.deleteScript = try c.decodeIfPresent(ScriptDefinition.self, forKey: .deleteScript)
  }

  /// Omit-when-default encoding. A lifecycle script with an empty
  /// `command` is treated as nil (the user effectively cleared it) so
  /// the JSON does not retain a stale UUID for an empty entry.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(worktreeBaseRef, forKey: .worktreeBaseRef)
    try c.encodeIfPresent(copyIgnoredOnWorktreeCreate, forKey: .copyIgnoredOnWorktreeCreate)
    try c.encodeIfPresent(copyUntrackedOnWorktreeCreate, forKey: .copyUntrackedOnWorktreeCreate)
    try c.encodeIfPresent(fetchRemoteOnWorktreeCreate, forKey: .fetchRemoteOnWorktreeCreate)
    try c.encodeIfPresent(defaultMergeStrategy, forKey: .defaultMergeStrategy)
    try c.encodeIfPresent(postMergeAction, forKey: .postMergeAction)
    if githubDisabled {
      try c.encode(true, forKey: .githubDisabled)
    }
    if let createScript, !createScript.command.isEmpty {
      try c.encode(createScript, forKey: .createScript)
    }
    if let archiveScript, !archiveScript.command.isEmpty {
      try c.encode(archiveScript, forKey: .archiveScript)
    }
    if let deleteScript, !deleteScript.command.isEmpty {
      try c.encode(deleteScript, forKey: .deleteScript)
    }
  }
}
