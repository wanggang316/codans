import CodansCore
import SwiftUI

/// Per-pane actions menu, anchored to the pane's top-right corner.
///
/// Collapsed it is a single button, with a queue button beneath it while the
/// pane holds queued commands. Expanded it lists the actions that are a property
/// of *this* pane — handing its agent's task off to another agent, opening
/// its command queue — so the pane is where they live. It shows no workspace
/// facts on purpose: the worktree's path, branch and uncommitted counts are
/// already in the header and sidebar, and the agent in the Agents view, so
/// repeating them here only duplicated what the eye had just passed.
///
/// The button holds its position across both states, so expanding reads as
/// the card growing out from under it rather than as a separate surface
/// appearing. It is deliberately not an `NSPopover`: a popover whose SwiftUI
/// content resizes after presentation crashes — see `AgentSessionSummaryCard`
/// — and this card will grow rows as actions are added.
struct PaneHUDView: View {
  let paneID: PaneID

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(AgentStateStore.self) private var agentStateStore: AgentStateStore?
  @Environment(\.paneHUDActions) private var actions

  @State private var isExpanded = false
  @State private var isButtonHovered = false
  @State private var isQueueButtonHovered = false

  private static let cardCornerRadius: CGFloat = 10
  /// Definite width for the expanded card. The action rows are deliberately
  /// greedy — the whole strip is the tap target — so something has to bound
  /// them. Without a definite width here they resolve against the overlay's
  /// proposal, which is the entire pane, and the card swallows the terminal.
  private static let cardWidth: CGFloat = 176
  /// Chrome box around the glyph. Deliberately larger than the 13pt symbol:
  /// at 22pt the fill read as a tight outline rather than a control.
  private static let buttonSize: CGFloat = 30
  private static let buttonCornerRadius: CGFloat = 8
  private static let expansion = Animation.snappy(duration: 0.24, extraBounce: 0.02)
  /// Inset from the container's top-right corner to the button, applied in
  /// both states so the button is the fixed point the card grows away from.
  private static let chromeInset: CGFloat = 10

  var body: some View {
    if let model = resolveModel() {
      card(model)
        // Squares the button off the pane's corner: with the container's own
        // `chromeInset` this puts it 14pt in from both edges. The vertical
        // half also has to clear `PaneDragHandle`, a 10pt full-width strip
        // `LeafView` layers over the same surface and above this overlay —
        // under it, hovering the button's top edge would arm a pane drag.
        .padding(.top, 4)
        .padding(.trailing, 4)
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
      agent: agentStateStore?.entries[paneID]?.kind
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
      // so the corner stays one column of same-sized controls.
      VStack(spacing: 6) {
        menuButton(model)
        if model.queuedCommandCount > 0 {
          queueButton(model)
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
    chrome(cornerRadius: Self.cardCornerRadius)
      .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
      .opacity(isExpanded ? 1 : 0)
      // Hit testing follows visibility, which `opacity` alone does not do: a
      // fully transparent shape still takes clicks. Collapsed, this shape is
      // the button's padding frame, and it would swallow terminal clicks in
      // the ring around the button. Expanded it must take them, so a click
      // inside the card does not also land in the terminal behind it.
      .allowsHitTesting(isExpanded)
  }

  /// Frosted fill plus a hairline edge. Terminal output sits directly behind
  /// this, so the fill is what stops glyphs reading through the control; the
  /// edge is what separates it from output of a similar tone.
  private func chrome(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(.regularMaterial)
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
      )
  }

  private func menuButton(_ model: PaneHUDModel) -> some View {
    Button {
      setExpanded(!isExpanded)
    } label: {
      // The system's "more actions" glyph: this is a menu of things to do to
      // the pane, not a readout about it.
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 13, weight: .regular))
        // Full strength always. Fading the glyph left terminal text legible
        // through it, which read as a rendering fault rather than restraint.
        .foregroundStyle(isButtonHovered ? Color.primary : Color.secondary)
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .background {
          // Expanded, the card behind the button already provides both.
          chrome(cornerRadius: Self.buttonCornerRadius)
            .opacity(isExpanded ? 0 : 1)
            // The button's own `contentShape` defines its hit area; this is
            // decoration and must not widen it.
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isButtonHovered = $0 }
    .accessibilityIdentifier("pane_hud.toggle")
    .accessibilityLabel(isExpanded ? "Hide pane actions" : "Show pane actions")
  }

  /// Opens the Command Queue sheet directly. Same box as the menu button so
  /// the two read as one stack; static, because a parked queue is a state to
  /// glance at rather than an alarm.
  private func queueButton(_ model: PaneHUDModel) -> some View {
    Button {
      setExpanded(false)
      actions.commandQueue(paneID)
    } label: {
      Image(systemName: CommandQueueStyle.symbol)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(isQueueButtonHovered ? Color.primary : Color.secondary)
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .background {
          chrome(cornerRadius: Self.buttonCornerRadius)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isQueueButtonHovered = $0 }
    .help(Self.queuedPhrase(model))
    .accessibilityIdentifier("pane_hud.queue")
    .accessibilityLabel("Command queue, \(Self.queuedPhrase(model))")
  }

  private static func queuedPhrase(_ model: PaneHUDModel) -> String {
    let count = model.queuedCommandCount
    return count == 1 ? "1 queued command" : "\(count) queued commands"
  }

  // MARK: - Expanded body

  private func expandedBody(_ model: PaneHUDModel) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      handOffButton(model)
      commandQueueButton(model)
    }
    .frame(width: Self.cardWidth, alignment: .leading)
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
          .frame(width: 14, height: 14, alignment: .center)
          .accessibilityHidden(true)
        Text("Command Queue…")
        Spacer(minLength: 0)
        if model.queuedCommandCount > 0 {
          Text("\(model.queuedCommandCount)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
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
}
