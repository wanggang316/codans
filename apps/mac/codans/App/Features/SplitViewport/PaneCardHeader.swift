import CodansCore
import ComposableArchitecture
import SwiftUI

/// Title row at the top of a pane card: the pane's glyph and live title on
/// the leading side, session history / split / close actions on the trailing
/// side.
///
/// The header is also the pane's grab handle: in a multi-pane Tab a drag
/// that starts on it moves the pane, the same drag the drop targets in
/// `LeafView` accept. A click focuses the pane.
///
/// The owner decides when the actions show. The actions menu button is not
/// drawn here: `PaneCommandQueueChrome` lays it over the slot this header
/// leaves free left of the close button, because its expanded card has to
/// draw above the terminal.
struct PaneCardHeader: View {
  let paneID: PaneID
  let tabID: TabID
  /// The title row is draggable only when there is another pane to move
  /// next to.
  let isSplit: Bool
  let isFocused: Bool
  let showsActions: Bool
  let onFocus: () -> Void
  let onSplit: (SplitTree<PaneID>.NewDirection) -> Void
  let onClose: () -> Void
  /// Drop of this pane on an edge of another pane in the Tab.
  let onMove: (_ anchor: PaneID, _ zone: PaneDropZone) -> Void
  /// Whether the queued-commands list under the header is open. The queue
  /// badge toggles it.
  @Binding var isQueueListShown: Bool

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
  @Environment(PaneMoveSession.self) private var moveSession
  @Dependency(TerminalClient.self) private var terminalClient

  /// Pointer over the glyph and title. In a split Tab this shows the move
  /// affordance.
  @State private var isHoveringTitle = false

  var body: some View {
    HStack(spacing: 0) {
      titleChip
      Spacer(minLength: 8)
      if queuedCount > 0 {
        queueBadge
          .padding(.trailing, PaneCardMetrics.actionSpacing)
          .transition(.opacity)
      }
      if showsActions {
        actions
          .transition(.opacity)
      }
    }
    .padding(.horizontal, PaneCardMetrics.headerHorizontalInset)
    .frame(height: PaneCardMetrics.headerHeight)
    .contentShape(.rect)
    .onTapGesture(perform: onFocus)
    .accessibilityAddTraits(.isButton)
    .modifier(
      PaneHeaderMoveGesture(
        paneID: paneID, isEnabled: isSplit, title: title, session: moveSession,
        onMove: onMove))
  }

  /// Glyph and title. When the pane can move, hovering them swaps the glyph
  /// for a move mark on a capsule fill, to show the drag handle.
  private var titleChip: some View {
    let showsMoveAffordance = isSplit && (isHoveringTitle || moveSession.source == paneID)
    return HStack(spacing: PaneCardMetrics.titleChipSpacing) {
      Group {
        if showsMoveAffordance {
          Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: PaneCardMetrics.moveGlyphSize, weight: .medium))
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
        } else {
          glyph
        }
      }
      .frame(width: PaneCardMetrics.headerIconSize, height: PaneCardMetrics.headerIconSize)
      Text(title)
        .font(.system(size: PaneCardMetrics.headerTitleFontSize))
        .foregroundStyle(isFocused ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.leading, PaneCardMetrics.titleChipLeadingInset)
    .padding(.trailing, PaneCardMetrics.titleChipTrailingInset)
    .frame(height: PaneCardMetrics.titleChipHeight)
    .background(
      Capsule()
        .fill(Color.primary.opacity(showsMoveAffordance ? PaneCardMetrics.hoverFillOpacity : 0))
    )
    .contentShape(.capsule)
    .onHover { hovering in
      isHoveringTitle = hovering
      // An open hand tells the title is a handle; the move gesture closes it.
      guard isSplit, moveSession.source == nil else { return }
      (hovering ? NSCursor.openHand : NSCursor.arrow).set()
    }
    .animation(.easeOut(duration: 0.12), value: showsMoveAffordance)
  }

  private var queuedCount: Int {
    pane?.commandQueue.count ?? 0
  }

  /// Count of queued commands. Always shown while any wait, since it is
  /// state rather than an action; a click opens the list.
  private var queueBadge: some View {
    Button {
      isQueueListShown.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: CommandQueueStyle.symbol)
          .font(.system(size: PaneCardMetrics.actionGlyphSize - 1, weight: .medium))
          .accessibilityHidden(true)
        Text("\(queuedCount)")
          .font(.system(size: 11, weight: .semibold))
          .monospacedDigit()
      }
      .foregroundStyle(Color.accentColor)
      .padding(.horizontal, 8)
      .frame(height: PaneCardMetrics.actionButtonSize)
      .background(
        Capsule().fill(Color.accentColor.opacity(isQueueListShown ? 0.24 : 0.14))
      )
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .help(isQueueListShown ? "Hide Queued Commands" : "Show Queued Commands")
    .accessibilityIdentifier("pane_hud.queue")
    .accessibilityLabel(
      queuedCount == 1 ? "1 queued command" : "\(queuedCount) queued commands")
  }

  private var actions: some View {
    HStack(spacing: PaneCardMetrics.actionSpacing) {
      if let worktree = SessionHistoryButton.worktree(of: paneID, in: hierarchyManager) {
        SessionHistoryButton(paneID: paneID, worktree: worktree, onPress: onFocus)
      }
      PaneCardHeaderButton(
        systemImage: "square.split.2x1", hoverSystemImage: "square.righthalf.filled",
        help: "Split Right"
      ) {
        onSplit(.right)
      }
      PaneCardHeaderButton(
        systemImage: "square.split.1x2", hoverSystemImage: "square.bottomhalf.filled",
        help: "Split Down"
      ) {
        onSplit(.down)
      }
      // Actions menu slot, see the type comment.
      Color.clear
        .frame(width: PaneCardMetrics.actionButtonSize, height: PaneCardMetrics.actionButtonSize)
      PaneCardHeaderButton(systemImage: "xmark", help: "Close Pane", action: onClose)
    }
  }

  /// The pane's `PaneGlyph`, which the tab chip also shows while this is
  /// the tab's selected pane. A running script's tint replaces the
  /// secondary style.
  private var glyph: some View {
    let glyph = PaneGlyph.resolve(
      pane: pane, settings: settingsStore?.settings ?? .default,
      isBusy: hierarchyManager.paneIsBusy(paneID))
    return StoredIconGlyph(icon: glyph.icon, markSize: PaneCardMetrics.headerIconSize)
      .font(.system(size: PaneCardMetrics.headerIconSize - 2))
      .foregroundStyle(
        glyph.tint.map { AnyShapeStyle(ScriptTintColorPalette.color(for: $0)) }
          ?? AnyShapeStyle(.secondary))
      .accessibilityHidden(true)
  }

  private var pane: Pane? {
    hierarchyManager.catalog.pane(paneID)
  }

  /// Live OSC title first, then the live working directory, then the
  /// persisted working directory, so a cold pane is never untitled.
  private var title: String {
    if let surface = terminalClient.surface(paneID) {
      let info = surface.info
      // Read every observable property so a later push on any of them
      // re-renders the header.
      let titleValue = info.title
      let pwdValue = info.pwd
      if let titleValue, !titleValue.isEmpty { return titleValue }
      if let pwdValue, !pwdValue.isEmpty {
        return (pwdValue as NSString).abbreviatingWithTildeInPath
      }
    }
    if let directory = pane?.workingDirectory, !directory.isEmpty {
      return (directory as NSString).abbreviatingWithTildeInPath
    }
    return "Terminal"
  }
}

/// Makes the header the handle of a pane move. A single-pane Tab has
/// nowhere to move the pane, so there the header starts no move at all.
private struct PaneHeaderMoveGesture: ViewModifier {
  let paneID: PaneID
  let isEnabled: Bool
  let title: String
  let session: PaneMoveSession
  let onMove: (_ anchor: PaneID, _ zone: PaneDropZone) -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .gesture(
          DragGesture(minimumDistance: 3, coordinateSpace: .named(PaneMoveSession.coordinateSpace))
            .onChanged { value in
              session.drag(paneID, title: title, to: value.location)
              // Set on every move: the pointer crosses terminals, which set
              // their own cursor.
              NSCursor.closedHand.set()
            }
            .onEnded { _ in
              NSCursor.arrow.set()
              guard let drop = session.finish(), drop.source == paneID else { return }
              onMove(drop.anchor, drop.zone)
            }
        )
        // A Tab switch can remove the header in the middle of a move.
        .onDisappear {
          if session.source == paneID { session.cancel() }
        }
    } else {
      content
    }
  }
}

/// Borderless glyph button with a capsule hover fill. It can swap to a
/// different glyph while hovered.
private struct PaneCardHeaderButton: View {
  let systemImage: String
  var hoverSystemImage: String?
  let help: String
  /// Command whose chord the tooltip appends.
  var shortcut: CommandID?
  let action: () -> Void

  @Environment(\.resolvedShortcuts) private var resolvedShortcuts
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: isHovering ? hoverSystemImage ?? systemImage : systemImage)
        .font(.system(size: PaneCardMetrics.actionGlyphSize, weight: .regular))
        .foregroundStyle(isHovering ? .primary : .secondary)
        .frame(width: PaneCardMetrics.actionButtonSize, height: PaneCardMetrics.actionButtonSize)
        .background(
          Capsule()
            .fill(Color.primary.opacity(isHovering ? PaneCardMetrics.hoverFillOpacity : 0))
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(tooltip)
    .accessibilityLabel(help)
    .onHover { isHovering = $0 }
  }

  private var tooltip: String {
    guard let shortcut else { return help }
    return ShortcutDisplay.tooltip(help, for: shortcut, in: resolvedShortcuts)
  }
}

/// Opens the pane's agent Session History popover, anchored to the button.
/// ⌘Y toggles the same popover on the focused pane. A press also focuses
/// the pane, so the header actions stay up while the popover is open and
/// In Place / New Split resume into this pane.
private struct SessionHistoryButton: View {
  let paneID: PaneID
  let worktree: Worktree
  let onPress: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.paneHUDActions) private var actions
  @State private var isPresented = false

  var body: some View {
    PaneCardHeaderButton(
      systemImage: "clock.arrow.circlepath", help: "Session History",
      shortcut: .showSessionHistory
    ) {
      onPress()
      isPresented.toggle()
    }
    .accessibilityIdentifier("pane_hud.session_history")
    .agentSessionHistoryPopover(
      isPresented: $isPresented,
      worktreePath: worktree.path,
      remoteHost: project?.remoteHost,
      resumeContext: AgentResumePlacement.Context(worktree: worktree) {
        hierarchyManager.lastFocusedPane(in: $0)
      },
      onResume: { session, placement in
        actions.resumeSession(paneID, session, placement)
      },
    )
    .onSessionHistoryRequest(for: paneID, isPresented: $isPresented)
  }

  private var project: Project? {
    hierarchyManager.catalog.projects.first { $0.worktrees.contains { $0.id == worktree.id } }
  }

  /// Resolved on every render, so a moved or pruned pane shows no button
  /// rather than a stale list.
  @MainActor
  static func worktree(of paneID: PaneID, in hierarchyManager: HierarchyManager) -> Worktree? {
    guard let (projectID, worktreeID, _) = hierarchyManager.addressOf(paneID: paneID) else {
      return nil
    }
    return hierarchyManager.catalog.projects.first { $0.id == projectID }?
      .worktrees.first { $0.id == worktreeID }
  }
}
