import Foundation
import os.log

/// `notifications` sub-tree of `settings.json` (v3, additive in v1.1). Carries the
/// global on/off knobs for the v1.1 notifications system — in-app inbox, system
/// banners, sound, dock badge — plus the "command finished" detector knobs and the
/// per-rule / per-pane mute sets. The section is optional in the parent decode so
/// pre-v1.1 `settings.json` files keep loading; missing fields fall back to defaults
/// via `decodeIfPresent`.
///
/// All fields are written explicitly on encode (no `encodeIfPresent`, no
/// "skip-if-default" elisions) so a settings.json diff makes the user's notification
/// state visible at a glance.
public nonisolated struct NotificationsSettings: Equatable, Sendable, Codable {
  /// In-app inbox surface. When false the inbox does not collect or display new
  /// entries; existing entries are preserved on disk.
  public var inAppEnabled: Bool
  /// System-level `UserNotifications` banners. When false the OS banner / Notification
  /// Center entry is suppressed even if the in-app inbox accepts the notification.
  public var systemEnabled: Bool
  /// Optional sound on system delivery. Honoured only when `systemEnabled` is also true.
  public var soundEnabled: Bool
  /// Dock-tile unread badge. Independent of `inAppEnabled` because the badge can act as
  /// a peripheral cue even when the user hides the inbox.
  public var dockBadgeEnabled: Bool
  /// Show the unread bell button + popover in the worktree status bar.
  /// All four `<level>BellEnabled` knobs are visual-only filters on the
  /// always-computed `RollupIndex` data — the inbox itself still receives
  /// every event (gated by `inAppEnabled`), they just hide the per-level
  /// indicator. Default on; users opt out per level if they want a quieter
  /// surface area.
  public var statusBarBellEnabled: Bool
  /// Show the project-level unread bell glyph in the sidebar.
  public var projectBellEnabled: Bool
  /// Show the worktree-level unread bell glyph in the sidebar.
  public var worktreeBellEnabled: Bool
  /// Show the tab-level unread dot on the tab strip.
  public var tabBellEnabled: Bool
  /// Promote the worktree associated with a freshly delivered notification to the top
  /// of the sidebar's recency-sorted list.
  public var moveNotifiedWorktreeToTop: Bool
  /// Master switch for the "command finished" detector. When false, the detector
  /// produces nothing regardless of threshold.
  public var commandFinishedEnabled: Bool
  /// Minimum runtime (seconds) before a finished command qualifies for a notification.
  /// Clamped to `[1, 3600]` on decode (the load-bearing defence against hand-edited
  /// `settings.json`); values outside the range trigger a single warning log line and
  /// are replaced with the clamped value. In-process callers (e.g. the Settings UI)
  /// are expected to validate before assigning — the memberwise init does not clamp,
  /// so out-of-range programmer error surfaces rather than being silently corrected.
  public var commandFinishedThresholdSec: Int
  /// Per-rule and per-pane mute sets. Empty by default.
  public var mute: MuteSettings

  public init(
    inAppEnabled: Bool = true,
    systemEnabled: Bool = true,
    soundEnabled: Bool = true,
    dockBadgeEnabled: Bool = true,
    statusBarBellEnabled: Bool = true,
    projectBellEnabled: Bool = true,
    worktreeBellEnabled: Bool = true,
    tabBellEnabled: Bool = true,
    moveNotifiedWorktreeToTop: Bool = true,
    commandFinishedEnabled: Bool = true,
    commandFinishedThresholdSec: Int = 10,
    mute: MuteSettings = .init()
  ) {
    self.inAppEnabled = inAppEnabled
    self.systemEnabled = systemEnabled
    self.soundEnabled = soundEnabled
    self.dockBadgeEnabled = dockBadgeEnabled
    self.statusBarBellEnabled = statusBarBellEnabled
    self.projectBellEnabled = projectBellEnabled
    self.worktreeBellEnabled = worktreeBellEnabled
    self.tabBellEnabled = tabBellEnabled
    self.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    self.commandFinishedEnabled = commandFinishedEnabled
    self.commandFinishedThresholdSec = commandFinishedThresholdSec
    self.mute = mute
  }

  public static let `default` = NotificationsSettings()

  /// Inclusive bounds for `commandFinishedThresholdSec`. The lower bound matches the
  /// detector's minimum meaningful runtime; the upper bound (1 h) is the longest
  /// "still useful" debounce window we'd expect a user to configure interactively.
  /// Public so the Settings UI in the app target can validate input against the same
  /// range the decoder defends, avoiding magic-number drift across modules.
  public static let thresholdRange: ClosedRange<Int> = 1...3600

  private static func clampThreshold(_ value: Int) -> Int {
    min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
  }

  private enum CodingKeys: String, CodingKey {
    case inAppEnabled, systemEnabled, soundEnabled, dockBadgeEnabled
    case statusBarBellEnabled, projectBellEnabled, worktreeBellEnabled, tabBellEnabled
    case moveNotifiedWorktreeToTop
    case commandFinishedEnabled, commandFinishedThresholdSec
    case mute
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.inAppEnabled = try container.decodeIfPresent(Bool.self, forKey: .inAppEnabled) ?? true
    self.systemEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemEnabled) ?? true
    self.soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
    self.dockBadgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockBadgeEnabled) ?? true
    self.statusBarBellEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .statusBarBellEnabled) ?? true
    self.projectBellEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .projectBellEnabled) ?? true
    self.worktreeBellEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .worktreeBellEnabled) ?? true
    self.tabBellEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .tabBellEnabled) ?? true
    self.moveNotifiedWorktreeToTop =
      try container.decodeIfPresent(Bool.self, forKey: .moveNotifiedWorktreeToTop) ?? true
    self.commandFinishedEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .commandFinishedEnabled) ?? true

    let rawThreshold = try container.decodeIfPresent(Int.self, forKey: .commandFinishedThresholdSec) ?? 10
    let clamped = Self.clampThreshold(rawThreshold)
    if clamped != rawThreshold {
      let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "settings")
      logger.warning(
        "commandFinishedThresholdSec \(rawThreshold, privacy: .public) out of range [\(Self.thresholdRange.lowerBound, privacy: .public), \(Self.thresholdRange.upperBound, privacy: .public)]; clamped to \(clamped, privacy: .public)"
      )
    }
    self.commandFinishedThresholdSec = clamped

    self.mute = try container.decodeIfPresent(MuteSettings.self, forKey: .mute) ?? .init()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inAppEnabled, forKey: .inAppEnabled)
    try container.encode(systemEnabled, forKey: .systemEnabled)
    try container.encode(soundEnabled, forKey: .soundEnabled)
    try container.encode(dockBadgeEnabled, forKey: .dockBadgeEnabled)
    try container.encode(statusBarBellEnabled, forKey: .statusBarBellEnabled)
    try container.encode(projectBellEnabled, forKey: .projectBellEnabled)
    try container.encode(worktreeBellEnabled, forKey: .worktreeBellEnabled)
    try container.encode(tabBellEnabled, forKey: .tabBellEnabled)
    try container.encode(moveNotifiedWorktreeToTop, forKey: .moveNotifiedWorktreeToTop)
    try container.encode(commandFinishedEnabled, forKey: .commandFinishedEnabled)
    try container.encode(commandFinishedThresholdSec, forKey: .commandFinishedThresholdSec)
    try container.encode(mute, forKey: .mute)
  }
}

/// Mute sets for the notifications system. Rule IDs are opaque strings owned by the
/// rule engine; pane IDs are the canonical `PaneID` from the hierarchy. Both keys
/// are optional on decode — a missing key yields an empty set — so partial JSON
/// (e.g., a hand-edit that only mentions one of the two sets) does not fail to load.
/// Encoded as a JSON array of strings for `mutedRuleIDs`, and an array of
/// `{"raw":"<uuid>"}` objects for `mutedPaneIDs` via `PaneID`'s synthesised Codable.
public nonisolated struct MuteSettings: Equatable, Sendable, Codable {
  public var mutedRuleIDs: Set<String>
  public var mutedPaneIDs: Set<PaneID>

  public init(
    mutedRuleIDs: Set<String> = [],
    mutedPaneIDs: Set<PaneID> = []
  ) {
    self.mutedRuleIDs = mutedRuleIDs
    self.mutedPaneIDs = mutedPaneIDs
  }

  private enum CodingKeys: String, CodingKey {
    case mutedRuleIDs, mutedPaneIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.mutedRuleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .mutedRuleIDs) ?? []
    self.mutedPaneIDs = try container.decodeIfPresent(Set<PaneID>.self, forKey: .mutedPaneIDs) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mutedRuleIDs, forKey: .mutedRuleIDs)
    try container.encode(mutedPaneIDs, forKey: .mutedPaneIDs)
  }
}
