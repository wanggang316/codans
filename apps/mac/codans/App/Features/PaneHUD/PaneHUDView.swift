import CodansCore
import SwiftUI

/// Per-pane actions menu. Its button sits in the pane card header, left of
/// the close button (`PaneCommandQueueChrome` places it there).
///
/// Collapsed it is a single button, with a queue button beneath it while the
/// pane holds queued commands. Expanded it lists the actions that are a property
/// of *this* pane. The first two are the pane's own affairs: handing its
/// agent's task off and opening its command queue. Under them sits every
/// action the terminal surface offers — copy, paste,
/// the four splits, reset, the pane id, close — rendered from the same
/// `PaneSurfaceAction.groups` the surface's right-click menu is built from,
/// so neither menu can quietly offer less than the other. The corner button
/// is how the actions are found; right-click is how they are reached quickly
/// once known.
///
/// It shows no workspace facts on purpose: the worktree's path, branch and
/// uncommitted counts are already in the header and sidebar, and the agent in
/// the Agents view, so repeating them here only duplicated what the eye had
/// just passed.
///
/// The button holds its position across both states, so expanding reads as
/// the card growing out from under it rather than as a separate surface
/// appearing. It is deliberately not an `NSPopover`: a popover whose SwiftUI
/// content resizes after presentation crashes — see `AgentSessionSummaryCard`
/// — and this card will grow rows as actions are added.
struct PaneHUDView: View {
  let paneID: PaneID
  /// The pane's live terminal surface, which services every
  /// `PaneSurfaceAction` row. Optional only for hosts that render the card
  /// without a running pane (the HUD render tests, previews); `LazyPaneHost`
  /// mounts the HUD alongside the surface, so in the app it is always there.
  /// Without one those rows render disabled rather than vanishing.
  let surface: PaneSurface?
  let onShowQueue: () -> Void
  /// Called when the menu button is pressed, before the card opens or
  /// closes.
  var onMenuPressed: () -> Void = {}

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(AgentStateStore.self) private var agentStateStore: AgentStateStore?
  @Environment(\.paneHUDActions) private var actions

  @State private var isExpanded: Bool
  @State private var isButtonHovered = false
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  /// `expanded` seeds the card's state. The app always starts collapsed;
  /// the seed exists so a rendering test can lay out the open card.
  init(
    paneID: PaneID, surface: PaneSurface? = nil, expanded: Bool = false,
    onShowQueue: @escaping () -> Void = {},
    onMenuPressed: @escaping () -> Void = {},
  ) {
    self.onShowQueue = onShowQueue
    self.onMenuPressed = onMenuPressed
    self.paneID = paneID
    self.surface = surface
    _isExpanded = State(initialValue: expanded)
  }

  private static let cardCornerRadius: CGFloat = 10
  /// Definite width for the expanded card. The action rows are deliberately
  /// greedy — the whole strip is the tap target — so something has to bound
  /// them. Without a definite width here they resolve against the overlay's
  /// proposal, which is the entire pane, and the card swallows the terminal.
  private static let cardWidth: CGFloat = 210
  /// The menu button matches the other header action buttons.
  private static let menuButtonSize: CGFloat = PaneCardMetrics.actionButtonSize
  /// Queue button (hangs below the header, over the terminal) and the
  /// expanded card's rows.
  private static let buttonSize: CGFloat = 30
  private static let buttonCornerRadius: CGFloat = 8
  private static let expansion = Animation.snappy(duration: 0.24, extraBounce: 0.02)
  /// Inset from the container's top-right corner to the button, applied in
  /// both states so the button is the fixed point the card grows away from.
  static let chromeInset: CGFloat = 6
  /// Leading inset for the card's rows. The button's glyph sits 8.5pt inside
  /// its 30pt box and a row's 11pt glyph 1.5pt inside its 14pt box, so this
  /// is what puts the rows as far from the card's left edge as the glyph is
  /// from its right — measured, not eyeballed: without it the left inset is
  /// 7pt shorter than the right.
  private static let rowLeadingInset: CGFloat = 7

  var body: some View {
    if let model = resolveModel() {
      card(model)
    }
  }

  /// Every `isExpanded` write goes through here. Two of the three callers are
  /// not SwiftUI actions — the outside-click probe answers an AppKit event
  /// monitor, and the hand-off row collapses on its way out — so the
  /// animation is stated at the mutation rather than left to the view tree.
  private func setExpanded(_ expanded: Bool) {
    withAnimation(Self.expansion) { isExpanded = expanded }
  }

  private func resolveModel() -> PaneHUDModel? {
    PaneHUDModel.resolve(
      paneID: paneID,
      in: hierarchyManager.catalog,
      agent: agentStateStore?.entries[paneID]?.kind,
    )
  }

  // MARK: - Card

  private func card(_ model: PaneHUDModel) -> some View {
    HStack(alignment: .top, spacing: 8) {
      if isExpanded {
        expandedBody(model)
          // Unfolds from the button rather than fading in place: the button
          // is the fixed point, so the card should read as growing out of it.
          .transition(
            .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity)
          )
      }
      // The queue button stacks under the menu button rather than beside it,
      // so the corner stays one column of same-sized controls. Collapsed
      // only: the expanded menu uses this space for its actions.
      VStack(alignment: .trailing, spacing: 6) {
        menuButton(model)
        if model.queuedCommandCount > 0, !isExpanded {
          queueButton(model)
            .transition(.opacity)
        }
      }
    }
    // Constant in both states on purpose. The button is a layout sibling of
    // the card body, so an equal inset from the container's top-right corner
    // is what holds it still while the card grows out from under it. A
    // smaller collapsed inset shifted the button by the difference, which
    // read as the whole control jumping on every open.
    .padding(Self.chromeInset)
    .background(cardBackground)
    .dismissOnClickOutside(isPresented: isExpanded) { setExpanded(false) }
  }

  /// Painted only for the expanded card. Collapsed, the container is the
  /// button's padding frame — filling that would draw a chip several times
  /// the button's size — so the button carries its own chrome instead.
  ///
  /// Both are kept in the tree and driven by opacity rather than inserted and
  /// removed, so the handover between them crossfades under the size
  /// animation instead of one popping out as the other appears.
  private var cardBackground: some View {
    Color.clear
      // The popup chrome itself (`FloatingCard`) rather than a local twin:
      // one recipe means the card can never drift from the Command Palette
      // / Hand Off surfaces — same glass, hairline (0.12), and shadow.
      .floatingCard(cornerRadius: Self.cardCornerRadius)
      .opacity(isExpanded ? 1 : 0)
      // Hit testing follows visibility, which `opacity` alone does not do: a
      // fully transparent shape still takes clicks. Collapsed, this shape is
      // the button's padding frame, and it would swallow terminal clicks in
      // the ring around the button. Expanded it must take them, so a click
      // inside the card does not also land in the terminal behind it.
      .allowsHitTesting(isExpanded)
  }

  /// Bare glass chip for the corner buttons — no shadow, because they are
  /// controls rather than cards. Same `.popover` material as the popup
  /// surfaces (`FloatingCard`), and the same 0.12 hairline, so button and
  /// card edges read identical; terminal output sits directly behind this,
  /// so the blur is what stops glyphs reading through the control.
  /// `.withinWindow` samples the terminal beneath the overlay, matching how
  /// the Command Palette card sees the split view.
  private func chrome(cornerRadius: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
      .clipShape(shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
  }

  private func menuButton(_ model: PaneHUDModel) -> some View {
    Button {
      onMenuPressed()
      setExpanded(!isExpanded)
    } label: {
      // The system's "more actions" glyph: this is a menu of things to do to
      // the pane, not a readout about it.
      Image(systemName: "ellipsis")
        .font(.system(size: PaneCardMetrics.actionGlyphSize, weight: .regular))
        .foregroundStyle(isButtonHovered ? Color.primary : Color.secondary)
        .frame(width: Self.menuButtonSize, height: Self.menuButtonSize)
        // Same hover fill as the other header buttons.
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(isButtonHovered && !isExpanded ? 0.08 : 0))
            .allowsHitTesting(false)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isButtonHovered = $0 }
    .accessibilityIdentifier("pane_hud.toggle")
    .accessibilityLabel(isExpanded ? "Hide pane actions" : "Show pane actions")
  }

  /// Restores the pane overlay without opening the composer.
  private func queueButton(_ model: PaneHUDModel) -> some View {
    Button {
      setExpanded(false)
      onShowQueue()
    } label: {
      VStack(spacing: 1) {
        Image(systemName: CommandQueueStyle.symbol)
          .font(.system(size: 11))
          .accessibilityHidden(true)
        Text("\(model.queuedCommandCount)")
          .font(.system(size: 9, weight: .semibold))
          .monospacedDigit()
      }
      .foregroundStyle(Color.accentColor)
      .frame(width: Self.buttonSize, height: Self.buttonSize)
      .background(chrome(cornerRadius: Self.buttonCornerRadius))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show queued commands")
    .accessibilityIdentifier("pane_hud.queue")
    .accessibilityLabel("Show command queue, \(Self.queuedPhrase(model))")
  }

  private static func queuedPhrase(_ model: PaneHUDModel) -> String {
    let count = model.queuedCommandCount
    return count == 1 ? "1 queued command" : "\(count) queued commands"
  }

  // MARK: - Expanded body

  private func expandedBody(_ model: PaneHUDModel) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // The pane's own affairs first: what its agent is doing and what is
      // queued for it.
      handOffButton(model)
      commandQueueButton(model)
      // Then everything the terminal surface offers, in the same order and
      // grouping as its right-click menu — the two are one list, so an
      // action is never in one menu and missing from the other.
      ForEach(Array(PaneSurfaceAction.groups.enumerated()), id: \.offset) { _, group in
        separator
        ForEach(group, id: \.self) { action in
          surfaceActionButton(action)
        }
      }
    }
    .padding(.leading, Self.rowLeadingInset)
    .frame(width: Self.cardWidth, alignment: .leading)
  }

  /// Group divider. The negative inset undoes the VStack's row inset so the
  /// rule spans the card's content width instead of starting at the glyph
  /// column.
  private var separator: some View {
    Divider()
      .padding(.leading, -Self.rowLeadingInset)
      .padding(.vertical, 4)
  }

  // MARK: - Actions

  @ViewBuilder
  private func handOffButton(_ model: PaneHUDModel) -> some View {
    Button {
      setExpanded(false)
      actions.handOff(paneID)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "arrow.left.arrow.right")
          .font(.system(size: 11))
          .frame(width: 14, height: 14, alignment: .center)
          .accessibilityHidden(true)
        Text("Hand Off…")
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      // Matches the button's own height, so the single-row card reads as a
      // menu item rather than a label floating in a box.
      .frame(minHeight: Self.buttonSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.canHandOff)
    .help(model.handOffBlockedReason ?? "Hand this task to another agent")
    .accessibilityIdentifier("pane_hud.hand_off")
  }

  private func commandQueueButton(_ model: PaneHUDModel) -> some View {
    Button {
      setExpanded(false)
      actions.commandQueue(paneID)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: CommandQueueStyle.symbol)
          .font(.system(size: 11))
          .accessibilityHidden(true)
          .frame(width: 14, height: 14, alignment: .center)
          .accessibilityHidden(true)
        Text("Command Queue…")
        Spacer(minLength: 0)
        if let shortcut = resolvedShortcuts[.toggleCommandQueue],
          shortcut.isEnabled, let binding = shortcut.binding
        {
          Text(ShortcutDisplay.chord(for: binding))
            .tracking(3)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }
      .font(.system(size: 12))
      .frame(minHeight: Self.buttonSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Queue commands to send to this pane")
    .accessibilityIdentifier("pane_hud.command_queue")
  }

  /// One row per `PaneSurfaceAction`, driven straight at the pane's surface
  /// — the same entry point the right-click menu items use, so a split from
  /// here lands in `PaneActionRouterFeature` exactly as one from there does
  /// and inherits its policy (closing a tab's last pane retires the tab, a
  /// sibling reclaims focus).
  private func surfaceActionButton(_ action: PaneSurfaceAction) -> some View {
    // Copy needs a selection to copy. Shown disabled rather than dropped, so
    // the card still answers "can this pane copy?" for someone who opened it
    // to find out what is here.
    let isEnabled = surface != nil && (!action.needsSelection || surface?.view.hasSelection == true)
    return Button {
      setExpanded(false)
      surface?.view.perform(action)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: action.symbol)
          .font(.system(size: 11))
          .frame(width: 14, height: 14, alignment: .center)
          .accessibilityHidden(true)
        Text(action.title)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12))
      .frame(minHeight: Self.buttonSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityIdentifier("pane_hud.\(action.accessibilityID)")
  }
}
