import Foundation

/// User's preferred handling of live panes at quit time. Replaces the legacy boolean
/// `resumePanesOnLaunch` with a tri-state strategy so the user can also choose to be
/// prompted on each quit. Migration of the legacy key is handled by
/// `GeneralSettings.init(from:)`.
public enum QuitStrategy: String, Codable, CaseIterable, Sendable, Equatable {
  /// Live tier: cmd-Q leaves pane daemons running so the next launch reattaches.
  case keepRunning
  /// Snapshot tier: quit serialises each pane's VT state and tears down the daemons;
  /// the next launch restores the visible buffer into a fresh shell.
  case snapshot
  /// Prompt the user each quit when at least one pane is live.
  case ask
}

/// `general` sub-tree of `settings.json` (v2). Carries the appearance placeholder, the
/// global default `EditorID`, and global defaults for the GitHub integration. C8a retired
/// the `customEditors` array that C8 shipped; legacy files that still carry it decode
/// cleanly (the field is simply ignored) and are re-serialised without it on the next save.
public nonisolated struct GeneralSettings: Equatable, Codable, Sendable {
  public var appearance: AppearancePreference
  /// Global default editor. `nil` means "no global default set" — resolution falls back to
  /// the `EditorRegistry.defaultPriority` walk (which always terminates at Finder).
  public var defaultEditorID: EditorID?
  /// Global default Git viewer. `nil` means "use the built-in Git Viewer overlay"; any
  /// other value names an installed git client from `EditorRegistry.gitClientPriority`
  /// (GitHub Desktop, Sourcetree, …) that should open instead when the user invokes the
  /// Git Viewer chord / menu item. A stored id that is no longer installed is treated
  /// as `nil` at resolve time and cleaned up by `garbageCollectEditors`.
  public var defaultGitViewerID: EditorID?
  /// Global default merge strategy used by the GitHub popover's Merge split-button when no
  /// per-Project `RepositorySettings.defaultMergeStrategy` is set. `nil` means "no global
  /// default" — the picker falls back to `.squash` for its initial value.
  public var defaultMergeStrategy: MergeStrategy?
  /// Global default post-merge Worktree action used by the GitHub integration when no
  /// per-Project override is set. `nil` means "no global default" — merging a PR presents
  /// the ask-each-time sheet.
  public var postMergeAction: MergedWorktreeAction?

  /// Sparkle release channel. Default `stable`. Drives `SPUUpdaterDelegate.allowedChannels(for:)`.
  /// The background-check cadence is a separate knob (`updateCheckInterval`) so flipping the
  /// channel no longer changes how often the app polls.
  public var updateChannel: UpdateChannel
  /// Background-check cadence, user-selectable. Default 24 h. Pushed to `SPUUpdater.updateCheckInterval`
  /// on launch and on every preference change.
  public var updateCheckInterval: UpdateCheckInterval
  /// Whether Sparkle should poll for updates in the background. Default `true`.
  public var updatesAutomaticallyCheckForUpdates: Bool
  /// Whether Sparkle should download + install updates without prompting. Default `false`
  /// because automatic install requires the app to relaunch and the user might be in the
  /// middle of a long-running terminal task. Only takes effect when
  /// `updatesAutomaticallyCheckForUpdates` is also true.
  public var updatesAutomaticallyDownloadUpdates: Bool

  /// Quit-time strategy for live panes. Default `.ask` — the quit confirmation dialog is
  /// presented whenever at least one pane is running. Legacy files that carry the retired
  /// boolean `resumePanesOnLaunch` key are migrated in `init(from:)`: `true` → `.keepRunning`,
  /// `false` → `.snapshot`.
  public var quitStrategy: QuitStrategy

  public init(
    appearance: AppearancePreference = .system,
    defaultEditorID: EditorID? = nil,
    defaultGitViewerID: EditorID? = nil,
    defaultMergeStrategy: MergeStrategy? = nil,
    postMergeAction: MergedWorktreeAction? = nil,
    updateChannel: UpdateChannel = .stable,
    updateCheckInterval: UpdateCheckInterval = .oneDay,
    updatesAutomaticallyCheckForUpdates: Bool = true,
    updatesAutomaticallyDownloadUpdates: Bool = false,
    quitStrategy: QuitStrategy = .ask
  ) {
    self.appearance = appearance
    self.defaultEditorID = defaultEditorID
    self.defaultGitViewerID = defaultGitViewerID
    self.defaultMergeStrategy = defaultMergeStrategy
    self.postMergeAction = postMergeAction
    self.updateChannel = updateChannel
    self.updateCheckInterval = updateCheckInterval
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    self.quitStrategy = quitStrategy
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey {
    case appearance, defaultEditorID, defaultGitViewerID, defaultMergeStrategy, postMergeAction
    case updateChannel, updateCheckInterval
    case updatesAutomaticallyCheckForUpdates, updatesAutomaticallyDownloadUpdates
    case quitStrategy
    /// Retired in favour of `quitStrategy`. Still decoded by `init(from:)` so legacy
    /// settings files migrate transparently on first launch.
    case resumePanesOnLaunch
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
    self.defaultEditorID = try container.decodeIfPresent(EditorID.self, forKey: .defaultEditorID)
    self.defaultGitViewerID = try container.decodeIfPresent(EditorID.self, forKey: .defaultGitViewerID)
    self.defaultMergeStrategy = try container.decodeIfPresent(MergeStrategy.self, forKey: .defaultMergeStrategy)
    self.postMergeAction = try container.decodeIfPresent(MergedWorktreeAction.self, forKey: .postMergeAction)
    self.updateChannel =
      try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .stable
    // Tolerate legacy files (key absent) and hand-edited invalid values: in either case we
    // fall back to the 24 h default rather than failing the whole settings decode.
    self.updateCheckInterval =
      (try? container.decodeIfPresent(UpdateCheckInterval.self, forKey: .updateCheckInterval))
      .flatMap { $0 } ?? .oneDay
    self.updatesAutomaticallyCheckForUpdates =
      try container.decodeIfPresent(Bool.self, forKey: .updatesAutomaticallyCheckForUpdates) ?? true
    self.updatesAutomaticallyDownloadUpdates =
      try container.decodeIfPresent(Bool.self, forKey: .updatesAutomaticallyDownloadUpdates) ?? false
    // Quit strategy: prefer the new key when present. Otherwise migrate the retired
    // `resumePanesOnLaunch` boolean (true → keepRunning, false → snapshot). Files that
    // carry neither — fresh installs and historical files written before either key
    // existed — fall back to `.ask` so the new install default surfaces the dialog.
    if let stored = try container.decodeIfPresent(QuitStrategy.self, forKey: .quitStrategy) {
      self.quitStrategy = stored
    } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .resumePanesOnLaunch) {
      self.quitStrategy = legacy ? .keepRunning : .snapshot
    } else {
      self.quitStrategy = .ask
    }
  }

  /// Explicit encoder so the retired `resumePanesOnLaunch` CodingKey (kept around purely
  /// to drive legacy-file migration in `init(from:)`) is never written back to disk. The
  /// synthesized `encode(to:)` would otherwise require a matching stored property or fail
  /// to compile.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(appearance, forKey: .appearance)
    try container.encodeIfPresent(defaultEditorID, forKey: .defaultEditorID)
    try container.encodeIfPresent(defaultGitViewerID, forKey: .defaultGitViewerID)
    try container.encodeIfPresent(defaultMergeStrategy, forKey: .defaultMergeStrategy)
    try container.encodeIfPresent(postMergeAction, forKey: .postMergeAction)
    try container.encode(updateChannel, forKey: .updateChannel)
    try container.encode(updateCheckInterval, forKey: .updateCheckInterval)
    try container.encode(
      updatesAutomaticallyCheckForUpdates, forKey: .updatesAutomaticallyCheckForUpdates)
    try container.encode(
      updatesAutomaticallyDownloadUpdates, forKey: .updatesAutomaticallyDownloadUpdates)
    try container.encode(quitStrategy, forKey: .quitStrategy)
  }
}
