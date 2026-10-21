import CodansCore
import SwiftUI

/// Observe activity in the icon instead of the hierarchy list builder.
struct SidebarWorktreeActivityIcon: View {
  let worktree: Worktree
  let agentStateStore: AgentStateStore?
  let snapshot: PullRequestSnapshot?
  let rollup: PullRequestBadge.CheckRollup
  let isSelected: Bool
  let glyph: WorktreeRowIcon.LeadingGlyph
  let isDefaultBranch: Bool
  let hasLifecycle: Bool

  @Environment(ContentRuntime.self) private var contentRuntime: ContentRuntime?
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?

  private var isExecuting: Bool {
    contentRuntime?.worktreeIsDirty(worktree) == true
      || worktree.contentIDs.contains { agentStateStore?.workingContentIDs.contains($0) == true }
  }

  var body: some View {
    if hasLifecycle || isExecuting {
      ProgressView()
        .controlSize(.small)
        .frame(width: 14, height: 14)
        .accessibilityLabel(hasLifecycle ? "Working" : "Worktree has a running command")
    } else {
      WorktreeRowIcon(
        snapshot: snapshot, rollup: rollup, isSelected: isSelected, glyph: glyph,
        hasUnreadNotification: notificationRollup?.current.unreadWorktrees.contains(worktree.id) == true
          && settingsStore.settings.notifications.worktreeBellEnabled,
        isDefaultBranch: isDefaultBranch
      )
    }
  }
}

struct SidebarWorktreeDiffStats: View {
  let worktreeID: WorktreeID
  @Environment(WorktreeLocalDiffMonitor.self) private var monitor

  var body: some View {
    if let stats = monitor.stats[worktreeID] ?? nil,
      stats.additions > 0 || stats.deletions > 0
    {
      DiffStatsChip(additions: stats.additions, deletions: stats.deletions)
        .padding(.leading, 6)
    }
  }
}

struct SidebarRunScriptAccessory: View {
  let worktreeID: WorktreeID
  let projectID: ProjectID
  let stop: () -> Void
  @Environment(ContentRuntime.self) private var contentRuntime: ContentRuntime?
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    let settings = settingsStore.settings
    let scripts = (settings.projects[projectID]?.scripts ?? []) + settings.general.globalScripts
    let tints =
      scripts
      .filter { contentRuntime?.isScriptRunning(worktreeID: worktreeID, scriptID: $0.id) == true }
      .map { ScriptTintColorPalette.color(for: $0.resolvedTintColor) }
    if !tints.isEmpty {
      RunScriptPingStopControl(colors: tints, onStop: stop)
        .padding(.leading, 6)
        .padding(.trailing, 2)
    }
  }
}
