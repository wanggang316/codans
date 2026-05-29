import Foundation

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

  /// Whether the AgentState sidebar panel should auto-open whenever any
  /// bound agent transitions into the `loading` state. Default `true`. When
  /// off, the panel only opens via the sidebar footer's toggle button. The
  /// panel + footer button stay visible regardless; this setting only
  /// controls the auto-open behaviour on the rising edge into `loading`.
  public var agentsViewAutoOpen: Bool

  /// Row density for the AgentState sidebar panel. `normal` (default)
  /// renders the two-line worktree/project identity column; `compact`
  /// joins both names on one line and tightens vertical padding.
  public var agentsViewDisplayMode: AgentsViewDisplayMode

  /// Whether the app uploads anonymous crash and error reports on release
  /// builds. Default `true`. Debug builds never report regardless of this
  /// flag. Flipping this off also clears the install identifier so a future
  /// re-enable starts a fresh anonymous id.
  public var crashReportsEnabled: Bool

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
    agentsViewAutoOpen: Bool = true,
    agentsViewDisplayMode: AgentsViewDisplayMode = .normal,
    crashReportsEnabled: Bool = true
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
    self.agentsViewAutoOpen = agentsViewAutoOpen
    self.agentsViewDisplayMode = agentsViewDisplayMode
    self.crashReportsEnabled = crashReportsEnabled
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey {
    case appearance, defaultEditorID, defaultGitViewerID, defaultMergeStrategy, postMergeAction
    case updateChannel, updateCheckInterval
    case updatesAutomaticallyCheckForUpdates, updatesAutomaticallyDownloadUpdates
    case agentsViewAutoOpen
    case agentsViewDisplayMode
    case crashReportsEnabled
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
    self.agentsViewAutoOpen =
      try container.decodeIfPresent(Bool.self, forKey: .agentsViewAutoOpen) ?? true
    // Older settings files predate this field. Default to `.normal` so
    // every existing install keeps the current two-line row layout
    // until the user opts into compact mode from Settings → General.
    self.agentsViewDisplayMode =
      try container.decodeIfPresent(AgentsViewDisplayMode.self, forKey: .agentsViewDisplayMode) ?? .normal
    // Older settings files predate this field. Default to opt-in to keep
    // installs already running through one or more releases consistent
    // with fresh installs; the user can opt out from Settings → General.
    self.crashReportsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .crashReportsEnabled) ?? true
  }
}
