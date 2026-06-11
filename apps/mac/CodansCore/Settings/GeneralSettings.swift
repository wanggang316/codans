import Foundation

/// User-facing "Confirm before quitting" preference. Decoupled from the action taken on
/// quit so that "ask vs don't ask" and "what to do" are orthogonal. Default `.auto`:
/// the quit dialog appears only when at least one pane is live; quitting with no live
/// panes never prompts. Migration of the retired `quitStrategy` / `resumePanesOnLaunch`
/// keys is handled by `GeneralSettings.init(from:)`.
public enum QuitConfirmation: String, Codable, CaseIterable, Equatable, Sendable {
  /// Ask only when there are active panes — the smart default.
  case auto
  /// Always present the dialog on quit, even with zero panes.
  case always
  /// Never present the dialog; apply `quitAction` directly.
  case never
}

/// User-facing "On quit" action. Drives both the no-dialog branch
/// (`applicationShouldTerminate` applies this directly when `QuitConfirmation` skips the
/// dialog) and the default-focused button in the dialog when it IS shown. Canonical home
/// for this enum lives in `CodansCore` so the runtime (`SessionLifecycle`) and the UI
/// layer share one definition without cyclic imports.
public enum QuitAction: String, Codable, CaseIterable, Equatable, Sendable {
  /// Live tier: cmd-Q leaves pane daemons running so the next launch reattaches.
  case keepRunning
  /// Snapshot tier: quit serialises each pane's VT state and tears down the daemons;
  /// the next launch restores the visible buffer into a fresh shell.
  case snapshot
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
  /// Global default Git viewer. `nil` means "not selected" — the Git Viewer chord /
  /// menu item is a no-op. Any other value names an installed git client from
  /// `EditorRegistry.gitClientPriority` (GitHub Desktop, Sourcetree, …) that the
  /// chord opens the current worktree in. A stored id that is no longer installed is
  /// treated as `nil` at resolve time and cleaned up by `garbageCollectEditors`.
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

  /// Whether to confirm at quit time. Default `.auto` (ask only when at least one pane is
  /// live). Orthogonal to `quitAction`, which decides what happens when the dialog is
  /// skipped or after the user picks the default button. Legacy files carrying the retired
  /// `quitStrategy` enum or the older `resumePanesOnLaunch` boolean are migrated in
  /// `init(from:)`.
  public var quitConfirmation: QuitConfirmation
  /// Default action taken on quit when no dialog is shown, and the focused button in the
  /// dialog when it IS shown. Default `.keepRunning` — long-running commands survive a
  /// quit by default.
  public var quitAction: QuitAction

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

  /// Whether the Agents View reorders rows by status (triage priority:
  /// needs-input, finished, working, idle). Default `true`. When off, rows
  /// hold the order they appeared in — new agents append at the end and the
  /// list never reshuffles. The reorder is debounced and skips decays into
  /// idle so a completed agent fading out doesn't make the list jump.
  public var agentsViewAutoSort: Bool

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
    quitConfirmation: QuitConfirmation = .auto,
    quitAction: QuitAction = .keepRunning,
    agentsViewAutoOpen: Bool = true,
    agentsViewDisplayMode: AgentsViewDisplayMode = .normal,
    agentsViewAutoSort: Bool = true,
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
    self.quitConfirmation = quitConfirmation
    self.quitAction = quitAction
    self.agentsViewAutoOpen = agentsViewAutoOpen
    self.agentsViewDisplayMode = agentsViewDisplayMode
    self.agentsViewAutoSort = agentsViewAutoSort
    self.crashReportsEnabled = crashReportsEnabled
  }

  public static let `default` = GeneralSettings()

  private enum CodingKeys: String, CodingKey {
    case appearance, defaultEditorID, defaultGitViewerID, defaultMergeStrategy, postMergeAction
    case updateChannel, updateCheckInterval
    case updatesAutomaticallyCheckForUpdates, updatesAutomaticallyDownloadUpdates
    case quitConfirmation, quitAction
    case agentsViewAutoOpen
    case agentsViewDisplayMode
    case agentsViewAutoSort
    case crashReportsEnabled
    /// Retired in favour of `quitConfirmation` + `quitAction`. Still decoded by
    /// `init(from:)` so legacy settings files migrate transparently on first launch.
    case quitStrategy
    /// Retired earlier than `quitStrategy`. Decoded by `init(from:)` as the last
    /// migration step so very old files still find their way to the new defaults.
    case resumePanesOnLaunch
  }

  /// Legacy enum kept private to drive the `quitStrategy` migration branch. The user-facing
  /// surface is `QuitConfirmation` + `QuitAction`; this exists only to decode old files.
  private enum LegacyQuitStrategy: String, Codable {
    case keepRunning
    case snapshot
    case ask
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
    // Quit-time settings migration chain (newest wins):
    //   1. quitConfirmation + quitAction present → use as-is.
    //   2. quitStrategy present → split: keepRunning/snapshot → (never, action); ask →
    //      (always, keepRunning). Matches the prior single-Picker semantics exactly.
    //   3. resumePanesOnLaunch present → (auto, true ? keepRunning : snapshot). The auto
    //      default carries the new "ask only when panes are live" behaviour to users who
    //      had only the boolean opt-in/out before.
    //   4. Neither present → defaults (auto, keepRunning).
    let storedConfirmation = try container.decodeIfPresent(QuitConfirmation.self, forKey: .quitConfirmation)
    let storedAction = try container.decodeIfPresent(QuitAction.self, forKey: .quitAction)
    if let storedConfirmation, let storedAction {
      self.quitConfirmation = storedConfirmation
      self.quitAction = storedAction
    } else if let legacyStrategy = try container.decodeIfPresent(
      LegacyQuitStrategy.self, forKey: .quitStrategy)
    {
      switch legacyStrategy {
      case .keepRunning:
        self.quitConfirmation = .never
        self.quitAction = .keepRunning
      case .snapshot:
        self.quitConfirmation = .never
        self.quitAction = .snapshot
      case .ask:
        self.quitConfirmation = .always
        self.quitAction = .keepRunning
      }
    } else if let legacyResume = try container.decodeIfPresent(Bool.self, forKey: .resumePanesOnLaunch) {
      self.quitConfirmation = .auto
      self.quitAction = legacyResume ? .keepRunning : .snapshot
    } else {
      self.quitConfirmation = .auto
      self.quitAction = .keepRunning
    }
    self.agentsViewAutoOpen =
      try container.decodeIfPresent(Bool.self, forKey: .agentsViewAutoOpen) ?? true
    // Older settings files predate this field. Default to `.normal` so
    // every existing install keeps the current two-line row layout
    // until the user opts into compact mode from Settings → General.
    self.agentsViewDisplayMode =
      try container.decodeIfPresent(AgentsViewDisplayMode.self, forKey: .agentsViewDisplayMode) ?? .normal
    // Older settings files predate this field. Default to on so existing
    // installs keep the status-ordered list they already had; the user can
    // opt out from Settings → General.
    self.agentsViewAutoSort =
      try container.decodeIfPresent(Bool.self, forKey: .agentsViewAutoSort) ?? true
    // Older settings files predate this field. Default to opt-in to keep
    // installs already running through one or more releases consistent
    // with fresh installs; the user can opt out from Settings → General.
    self.crashReportsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .crashReportsEnabled) ?? true
  }

  /// Explicit encoder so the retired `resumePanesOnLaunch` / `quitStrategy` CodingKeys
  /// (kept around purely to drive legacy-file migration in `init(from:)`) are never written
  /// back to disk. The synthesized `encode(to:)` would otherwise require matching stored
  /// properties or fail to compile.
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
    try container.encode(quitConfirmation, forKey: .quitConfirmation)
    try container.encode(quitAction, forKey: .quitAction)
    try container.encode(agentsViewAutoOpen, forKey: .agentsViewAutoOpen)
    try container.encode(agentsViewDisplayMode, forKey: .agentsViewDisplayMode)
    try container.encode(crashReportsEnabled, forKey: .crashReportsEnabled)
  }
}
