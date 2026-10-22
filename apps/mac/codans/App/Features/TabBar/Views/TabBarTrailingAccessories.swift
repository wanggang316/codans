import CodansCore
import SwiftUI

/// Fixed-position controls on the trailing edge of a Pane's tab strip.
/// Lives outside the scrollable chip row so these buttons stay visible
/// regardless of how many tabs are open.
///
/// Four actions: `+` creates a new Tab in this Pane (press-and-hold or
/// right-click it to start an agent in the new Tab instead); the session
/// history clock resumes a recorded agent session in a new Tab; the two
/// split buttons create a Pane beside this one. When `isFolded`, only `+`
/// shows and the other three become items of its menu (see
/// `TabBarMetrics.foldsAccessories`).
struct TabBarTrailingAccessories: View {
  /// Path of the Worktree, scanned by the session-history popover. `nil`
  /// while no Worktree is resolved — history hides since there is nothing
  /// to scan against.
  let worktreePath: String?
  /// SSH host of the Worktree's project for Server projects, `nil` for
  /// local — routes the session-history scan to the host's stores.
  var remoteHost: RemoteHost?
  /// Narrow strip: keep only `+`, fold the rest into its menu.
  var isFolded: Bool = false
  let onNewTab: () -> Void
  let onLaunchAgent: (_ profileID: UUID) -> Void
  let onManageAgents: () -> Void
  let onResumeSession: (AgentSessionSummary) -> Void
  let onSplitRight: () -> Void
  let onSplitDown: () -> Void

  /// Folded history: the menu item opens the same popover, anchored on `+`.
  @State private var foldedHistoryShown = false

  var body: some View {
    // No ⌘-held chord hints here: they would widen the accessories and
    // squeeze the tab row while the key is down. The tooltips still carry
    // each button's shortcut.
    HStack(spacing: TabBarMetrics.accessorySpacing) {
      newTabButton

      if !isFolded {
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
          action: onSplitRight
        )

        SplitAccessoryButton(
          systemImage: "rectangle.bottomhalf.inset.filled",
          accessibilityLabel: "Split Down",
          chordCommandID: .splitDown,
          action: onSplitDown
        )
      }
    }
    .padding(.horizontal, TabBarMetrics.accessoryClusterPadding)
  }

  @ViewBuilder
  private var newTabButton: some View {
    let button = NewTabAccessoryButton(
      action: onNewTab,
      onLaunchAgent: onLaunchAgent,
      onManageAgents: onManageAgents,
      foldedItems: isFolded ? foldedMenuItems : { [] }
    )
    if isFolded, let worktreePath {
      button.agentSessionHistoryPopover(
        isPresented: $foldedHistoryShown,
        worktreePath: worktreePath,
        remoteHost: remoteHost,
        onResume: onResumeSession
      )
    } else {
      button
    }
  }

  /// The controls a narrow strip hides, as `+` menu items below the agent
  /// profiles.
  private func foldedMenuItems() -> [NewTabMenuItem] {
    var items: [NewTabMenuItem] = []
    if worktreePath != nil {
      items.append(.action("Agent Session History…") { foldedHistoryShown = true })
    }
    items.append(.action("Split Right", perform: onSplitRight))
    items.append(.action("Split Down", perform: onSplitDown))
    return items
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
      .frame(width: TabBarMetrics.accessorySize, height: TabBarMetrics.accessorySize)
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
/// (the New Agent dialog's list) that each start in a new tab, plus a
/// "Manage Agents…" footer. A folded strip appends its hidden controls.
private struct NewTabAccessoryButton: View {
  let action: () -> Void
  let onLaunchAgent: (_ profileID: UUID) -> Void
  let onManageAgents: () -> Void
  let foldedItems: () -> [NewTabMenuItem]
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(AgentInstallationStore.self) private var installation
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .accessibilityLabel("New Tab")
        .modifier(AccessoryIconChrome(isHovering: isHovering))
    }
    .buttonStyle(.plain)
    .overlay(NewTabMenuOverlay(onClick: action, menuItems: menuItems))
    .onHover { isHovering = $0 }
    .helpWithShortcut("New Tab", .newTab)
  }

  private func menuItems() -> [NewTabMenuItem] {
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
    let folded = foldedItems()
    if !folded.isEmpty {
      items.append(.separator)
      items.append(contentsOf: folded)
    }
    return items
  }
}

/// Trailing split button. Mirrors a registry chord (`.splitRight` /
/// `.splitDown`) so the tooltip resolves the same binding. Always enabled:
/// a Pane always holds a Tab to split from.
private struct SplitAccessoryButton: View {
  let systemImage: String
  let accessibilityLabel: String
  let chordCommandID: CommandID
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .accessibilityLabel(accessibilityLabel)
        .modifier(AccessoryIconChrome(isHovering: isHovering))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .helpWithShortcut(accessibilityLabel, chordCommandID)
  }
}
