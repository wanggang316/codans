import SwiftUI
import CodansCore

/// Fixed-position controls on the trailing edge of the Tab bar. Lives
/// outside the scrollable chip row so these buttons stay visible
/// regardless of how many tabs are open.
///
/// Four actions: `+` creates a new tab in the active worktree (press-and-hold
/// or right-click it to start an agent in the new tab instead); the session
/// history clock resumes a recorded agent session in a new tab; the two
/// split buttons cut a new pane horizontally or vertically off the active
/// tab's leftmost leaf.
struct TabBarTrailingAccessories: View {
  let activeTabSplitTree: SplitTree<PaneID>?
  /// Path of the active worktree, scanned by the session-history popover.
  /// `nil` while no worktree is resolved — the history button hides since
  /// there is nothing to scan against.
  let worktreePath: String?
  /// SSH host of the active worktree's project for Server projects, `nil`
  /// for local — routes the session-history scan to the host's stores.
  var remoteHost: RemoteHost?
  let onNewTab: () -> Void
  let onLaunchAgent: (_ profileID: UUID) -> Void
  let onManageAgents: () -> Void
  let onResumeSession: (AgentSessionSummary) -> Void
  let onSplitRight: () -> Void
  let onSplitDown: () -> Void

  var body: some View {
    // 6pt rather than 4: while ⌘ is held each button grows a chord on its
    // trailing side, and the wider gap keeps that chord from crowding the
    // next button. The tight `commandKeyHint(spacing:)` on each accessory
    // is the other half of the same grouping.
    HStack(spacing: 6) {
      NewTabAccessoryButton(
        action: onNewTab, onLaunchAgent: onLaunchAgent, onManageAgents: onManageAgents)

      if let worktreePath {
        AgentSessionHistoryButton(
          worktreePath: worktreePath,
          remoteHost: remoteHost,
          onResume: onResumeSession
        )
      }

      SplitAccessoryButton(
        systemImage: "rectangle.righthalf.inset.filled",
        accessibilityLabel: "Split Right",
        chordCommandID: .splitRight,
        splitTree: activeTabSplitTree,
        action: onSplitRight
      )

      SplitAccessoryButton(
        systemImage: "rectangle.bottomhalf.inset.filled",
        accessibilityLabel: "Split Down",
        chordCommandID: .splitDown,
        splitTree: activeTabSplitTree,
        action: onSplitDown
      )
    }
    .padding(.horizontal, 6)
  }
}

/// 22×22 circular hover affordance shared by the trailing accessories.
/// Mirrors the sidebar `iconLabel` chrome so the +/split row reads as
/// the same family of toolbar icon buttons. `TabBarColors.hoverBackground`
/// gives the standard tab-bar tint; the `Circle()` shape rounds the hit
/// target without changing the underlying button hit detection.
private struct AccessoryIconChrome: ViewModifier {
  let isHovering: Bool

  func body(content: Content) -> some View {
    content
      .frame(width: 22, height: 22)
      .background(
        Circle()
          .fill(isHovering ? TabBarColors.hoverBackground : .clear)
      )
      .contentShape(Circle())
  }
}

/// `+` button. Split into its own view so the hover state is local and
/// doesn't redraw siblings on every pointer crossing.
///
/// Press-and-hold or right-click opens a menu of the offered agent profiles
/// (the toolbar Agents menu's list) that each start in a new tab, plus a
/// "Manage Agents…" footer.
private struct NewTabAccessoryButton: View {
  let action: () -> Void
  let onLaunchAgent: (_ profileID: UUID) -> Void
  let onManageAgents: () -> Void
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(AgentInstallationStore.self) private var installation
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .accessibilityLabel("New Tab")
        .modifier(AccessoryIconChrome(isHovering: isHovering))
        // The 22pt chrome already pads the glyph; a tight gap keeps the
        // chord attached to this icon instead of drifting toward the next.
        .commandKeyHint(.newTab, spacing: 2)
    }
    .buttonStyle(.plain)
    .overlay(NewTabMenuOverlay(onClick: action, menuItems: agentMenuItems))
    .onHover { isHovering = $0 }
    .helpWithShortcut("New Tab", .newTab)
  }

  private func agentMenuItems() -> [NewTabMenuItem] {
    let profiles = AgentInstallationStore.offeredProfiles(
      enabled: settingsStore.settings.agents.enabledProfiles,
      isInstalled: installation.isInstalled
    )
    var items = profiles.map { profile in
      NewTabMenuItem.action(
        profile.displayName, image: AgentMenuIcon.nsImage(for: profile.icon)
      ) { onLaunchAgent(profile.id) }
    }
    if !items.isEmpty { items.append(.separator) }
    items.append(.action("Manage Agents…", perform: onManageAgents))
    return items
  }
}

/// Trailing split button. Mirrors a registry chord (`.splitRight` /
/// `.splitDown`) so the chord glyph appears inline while ⌘ is held and
/// the tooltip resolves the same binding.
private struct SplitAccessoryButton: View {
  let systemImage: String
  let accessibilityLabel: String
  let chordCommandID: CommandID
  let splitTree: SplitTree<PaneID>?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .accessibilityLabel(accessibilityLabel)
        .modifier(AccessoryIconChrome(isHovering: isHovering))
        .commandKeyHint(chordCommandID, spacing: 2)
    }
    .buttonStyle(.plain)
    .disabled(splitTree?.root == nil)
    .onHover { isHovering = $0 }
    .helpWithShortcut(accessibilityLabel, chordCommandID)
  }
}
