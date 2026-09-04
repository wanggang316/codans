import CodansCore
import SwiftUI

/// Per-pane heads-up display, anchored to the pane's top-right corner.
///
/// Collapsed it is a single info button. Expanded it grows into a card naming
/// the worktree the pane runs in — path, branch, uncommitted line counts —
/// and the agent bound to it, plus the pane-scoped actions that need that
/// context. Handing the task off to another agent is the first: it is a
/// property of *this* pane's agent, so the pane is where it belongs.
///
/// The button holds its position across both states, so expanding reads as
/// the card growing out from under it rather than as a separate surface
/// appearing. It is deliberately not an `NSPopover`: this card's height
/// changes as the diff stats resolve, and a popover whose SwiftUI content
/// resizes after presentation crashes — see `AgentSessionSummaryCard`.
struct PaneHUDView: View {
  let paneID: PaneID

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(WorktreeLocalDiffMonitor.self) private var diffMonitor
  @Environment(AgentStateStore.self) private var agentStateStore: AgentStateStore?
  @Environment(\.paneHUDActions) private var actions

  @State private var isExpanded = false
  @State private var isButtonHovered = false

  private static let cardCornerRadius: CGFloat = 10
  /// Definite width for the expanded card. The rows below are deliberately
  /// greedy — a full-width divider, and an action row whose whole strip is the
  /// tap target — so something has to bound them. Without a definite width
  /// here they resolve against the overlay's proposal, which is the entire
  /// pane, and the card swallows the terminal.
  private static let cardWidth: CGFloat = 240
  private static let buttonSize: CGFloat = 22
  private static let buttonCornerRadius: CGFloat = 6
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

  private func resolveModel() -> PaneHUDModel? {
    PaneHUDModel.resolve(
      paneID: paneID,
      in: hierarchyManager.catalog,
      agent: agentStateStore?.entries[paneID]?.kind,
      diff: { diffMonitor.stats[$0] ?? nil },
      homeDirectory: NSHomeDirectory()
    )
  }

  // MARK: - Card

  private func card(_ model: PaneHUDModel) -> some View {
    HStack(alignment: .top, spacing: 8) {
      if isExpanded {
        expandedBody(model)
      }
      infoButton
    }
    // Constant in both states on purpose. The button is a layout sibling of
    // the card body, so an equal inset from the container's top-right corner
    // is what holds it still while the card grows out from under it. A
    // smaller collapsed inset shifted the button by the difference, which
    // read as the whole control jumping on every open.
    .padding(Self.chromeInset)
    .background(cardBackground)
    .dismissOnClickOutside(isPresented: isExpanded) { isExpanded = false }
    .animation(.snappy(duration: 0.22), value: isExpanded)
    // Refresh on expand rather than on a timer. The monitor holds a 5 s
    // freshness window and dedupes in-flight fetches, so re-opening the card
    // costs at most one `git diff --shortstat` and can never show a value
    // older than the last open.
    .task(id: isExpanded) {
      guard isExpanded else { return }
      await diffMonitor.refresh(
        worktreeID: model.worktreeID,
        path: URL(fileURLWithPath: model.worktreePath, isDirectory: true)
      )
    }
  }

  /// Only the expanded card is painted here. Collapsed, the container is the
  /// button's padding frame — filling that would draw a chip several times
  /// the button's size — so the button carries its own chrome instead.
  @ViewBuilder
  private var cardBackground: some View {
    if isExpanded {
      chrome(cornerRadius: Self.cardCornerRadius)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
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

  private var infoButton: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 13, weight: .regular))
        // Full strength always. Fading the glyph left terminal text legible
        // through it, which read as a rendering fault rather than restraint.
        .foregroundStyle(isButtonHovered ? Color.primary : Color.secondary)
        .frame(width: Self.buttonSize, height: Self.buttonSize)
        .background {
          // Expanded, the card behind the button already provides both.
          if !isExpanded {
            chrome(cornerRadius: Self.buttonCornerRadius)
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isButtonHovered = $0 }
    .accessibilityIdentifier("pane_hud.toggle")
    .accessibilityLabel(isExpanded ? "Hide pane details" : "Show pane details")
  }

  // MARK: - Expanded body

  private func expandedBody(_ model: PaneHUDModel) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Workspace")
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .kerning(0.6)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 5) {
        row {
          Image(systemName: "folder")
            .accessibilityHidden(true)
        } content: {
          Text(model.displayPath)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
        }
        row {
          Image(systemName: "arrow.triangle.branch")
            .accessibilityHidden(true)
        } content: {
          Text(model.branch ?? "(detached)")
            .lineLimit(1)
        }
        row {
          Image(systemName: "plusminus")
            .accessibilityHidden(true)
        } content: {
          diffStats(model.diff)
        }
        if let agent = model.agent {
          // The brand mark sits in the same leading column as the symbols
          // above, so all four rows share one text baseline column.
          row {
            AgentLogoView(kind: agent, size: 12)
          } content: {
            Text(agent.displayName)
          }
        }
      }
      .font(.system(size: 12))

      Divider()
      handOffButton(model)
    }
    .frame(width: Self.cardWidth, alignment: .leading)
  }

  /// One `<glyph> <value>` line. The leading slot is a fixed 14pt box in both
  /// axes so every row's text starts on the same x whether the glyph is an SF
  /// Symbol or an agent's brand mark, and so nothing in it can stretch the
  /// card.
  private func row<Leading: View, Content: View>(
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 7) {
      leading()
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 14, height: 14, alignment: .center)
        .accessibilityHidden(true)
      content()
    }
  }

  @ViewBuilder
  private func diffStats(_ diff: LocalDiffStats?) -> some View {
    if let diff {
      HStack(spacing: 5) {
        Text("+\(diff.additions)").foregroundStyle(DiffStatColor.additions)
        Text("−\(diff.deletions)").foregroundStyle(DiffStatColor.deletions)
      }
      .monospacedDigit()
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(diff.additions) additions, \(diff.deletions) deletions")
    } else {
      Text("—")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Uncommitted changes not measured yet")
    }
  }

  // MARK: - Actions

  @ViewBuilder
  private func handOffButton(_ model: PaneHUDModel) -> some View {
    Button {
      isExpanded = false
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
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.canHandOff)
    .help(model.handOffBlockedReason ?? "Hand this task to another agent")
    .accessibilityIdentifier("pane_hud.hand_off")
  }
}
