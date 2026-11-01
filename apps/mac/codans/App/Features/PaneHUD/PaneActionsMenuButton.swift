import AppKit
import CodansCore
import SwiftUI

/// Per-pane actions menu. Its button sits in the pane card header, left of
/// the close button (`PaneCommandQueueChrome` places it there).
///
/// The menu is a native `NSMenu`, pulled down under the button and built
/// when it opens, so every row reflects the pane as it is at that moment
/// (Copy needs a live selection). The first rows are the pane's own affairs:
/// handing its agent's task off, opening its command queue, and resuming a
/// recorded agent session from the Session History popover. Under them sits
/// every action the terminal surface offers, added by the surface itself
/// (`GhosttySurfaceView.addPaneActionItems(to:)`), so this menu and the
/// right-click menu can never offer different surface actions. The header
/// button is how the actions are found; right-click is how they are reached
/// quickly once known.
struct PaneActionsMenuButton: View {
  let paneID: PaneID
  /// The pane's live terminal surface, which services the surface rows.
  /// Without one (a pane still starting) the menu offers only the pane's
  /// own rows.
  let surface: PaneSurface?
  /// Called when the button is pressed, before the menu opens.
  var onMenuPressed: () -> Void = {}

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(AgentStateStore.self) private var agentStateStore: AgentStateStore?
  @Environment(\.paneHUDActions) private var actions
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  @State private var isHovered = false
  @State private var isMenuOpen = false
  /// The Session History popover, anchored to the button once the menu
  /// has closed.
  @State private var sessionHistoryShown = false
  @State private var anchor = PaneMenuAnchor()

  var body: some View {
    Button(action: openMenu) {
      Image(systemName: "ellipsis")
        .font(.system(size: PaneCardMetrics.actionGlyphSize, weight: .regular))
        .foregroundStyle(isHovered || isMenuOpen ? Color.primary : Color.secondary)
        .frame(width: PaneCardMetrics.actionButtonSize, height: PaneCardMetrics.actionButtonSize)
        // Same hover fill as the other header buttons. It stays while the
        // menu is open, as a pressed toolbar button does.
        .background(
          Capsule()
            .fill(
              Color.primary.opacity(isHovered || isMenuOpen ? PaneCardMetrics.hoverFillOpacity : 0))
        )
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .background(PaneMenuAnchorView(anchor: anchor))
    .onHover { isHovered = $0 }
    .modifier(SessionHistoryAnchor(paneID: paneID, isPresented: $sessionHistoryShown))
    .help("Pane Actions")
    .accessibilityIdentifier("pane_hud.toggle")
    .accessibilityLabel("Pane Actions")
  }

  private func openMenu() {
    onMenuPressed()
    guard
      let view = anchor.view,
      let model = PaneHUDModel.resolve(
        paneID: paneID, in: hierarchyManager.catalog,
        agent: agentStateStore?.entries[paneID]?.kind)
    else { return }
    let menu = makeMenu(model)
    // A pull-down: the menu's top-trailing corner under the button's
    // bottom-trailing corner, so it opens inward from the card edge.
    let x = view.bounds.maxX - menu.size.width
    let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
    isMenuOpen = true
    menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)
    isMenuOpen = false
  }

  private func makeMenu(_ model: PaneHUDModel) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let handOff = NSMenuItem.closure(title: "Hand Off…") { [actions, paneID] in
      actions.handOff(paneID)
    }
    handOff.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
    handOff.isEnabled = model.canHandOff
    handOff.toolTip = model.handOffBlockedReason
    handOff.setAccessibilityIdentifier("pane_hud.hand_off")
    menu.addItem(handOff)

    let queue = NSMenuItem.closure(title: "Command Queue…") { [actions, paneID] in
      actions.commandQueue(paneID)
    }
    queue.image = NSImage(systemSymbolName: CommandQueueStyle.symbol, accessibilityDescription: nil)
    if let shortcut = resolvedShortcuts[.toggleCommandQueue], shortcut.isEnabled,
      let binding = shortcut.binding,
      let key = ShortcutDisplay.keyEquivalent(for: binding.keyCode)
    {
      // Display only: an item of a pop-up menu answers its key equivalent
      // only while the menu is open.
      queue.keyEquivalent = String(key.character)
      queue.keyEquivalentModifierMask = Self.modifierFlags(binding.modifiers)
    }
    queue.setAccessibilityIdentifier("pane_hud.command_queue")
    menu.addItem(queue)

    if SessionHistoryAnchor.worktree(of: paneID, in: hierarchyManager) != nil {
      let history = NSMenuItem.closure(title: "Session History…") {
        sessionHistoryShown = true
      }
      history.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
      history.setAccessibilityIdentifier("pane_hud.session_history")
      menu.addItem(history)
    }

    if let surfaceView = surface?.view {
      menu.addItem(.separator())
      surfaceView.addPaneActionItems(to: menu)
    }
    return menu
  }

  private static func modifierFlags(_ mask: ModifierMask) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mask.contains(.command) { flags.insert(.command) }
    if mask.contains(.option) { flags.insert(.option) }
    if mask.contains(.control) { flags.insert(.control) }
    if mask.contains(.shift) { flags.insert(.shift) }
    return flags
  }
}

/// Holds the AppKit view the actions menu is positioned against.
@MainActor
final class PaneMenuAnchor {
  weak var view: NSView?

  // Explicit (nonisolated) deinit: SwiftUI releases this `@State` object
  // inside a view-tree teardown, where a synthesized isolated deinit
  // double-frees (see `PaneMoveSession`).
  deinit {}
}

private struct PaneMenuAnchorView: NSViewRepresentable {
  let anchor: PaneMenuAnchor

  func makeNSView(context: Context) -> NSView {
    let view = PassThroughView()
    anchor.view = view
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    anchor.view = nsView
  }

  /// Takes no clicks: the SwiftUI button above it owns them.
  private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// Hosts the Session History popover on the menu button. Resolves the
/// pane's worktree at presentation time, so a moved or pruned pane shows
/// nothing rather than a stale list.
private struct SessionHistoryAnchor: ViewModifier {
  let paneID: PaneID
  @Binding var isPresented: Bool

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(\.paneHUDActions) private var actions

  func body(content: Content) -> some View {
    if let worktree = Self.worktree(of: paneID, in: hierarchyManager) {
      content.agentSessionHistoryPopover(
        isPresented: $isPresented,
        worktreePath: worktree.path,
        remoteHost: project(of: worktree)?.remoteHost,
        resumeContext: AgentResumePlacement.Context(worktree: worktree) {
          hierarchyManager.lastFocusedPane(in: $0)
        },
        onResume: { session, placement in
          actions.resumeSession(paneID, session, placement)
        },
      )
    } else {
      content
    }
  }

  private func project(of worktree: Worktree) -> Project? {
    hierarchyManager.catalog.projects.first { $0.worktrees.contains { $0.id == worktree.id } }
  }

  @MainActor
  static func worktree(of paneID: PaneID, in hierarchyManager: HierarchyManager) -> Worktree? {
    guard let (projectID, worktreeID, _) = hierarchyManager.addressOf(paneID: paneID) else {
      return nil
    }
    return hierarchyManager.catalog.projects.first { $0.id == projectID }?
      .worktrees.first { $0.id == worktreeID }
  }
}
