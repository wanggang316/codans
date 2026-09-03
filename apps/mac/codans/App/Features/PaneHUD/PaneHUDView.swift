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

  var body: some View {
    if let model = resolveModel() {
      card(model)
        .padding(8)
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
    .padding(isExpanded ? 12 : 3)
    .background(background)
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

  @ViewBuilder
  private var background: some View {
    if isExpanded {
      RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    } else {
      // Collapsed the chrome is only a hover affordance — an always-on chip
      // would sit on top of terminal output in every pane of every split.
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(.regularMaterial)
        .opacity(isButtonHovered ? 1 : 0)
    }
  }

  private var infoButton: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Image(systemName: "info.circle")
        .font(.system(size: 13))
        .foregroundStyle(isExpanded || isButtonHovered ? .primary : .secondary)
        .opacity(isExpanded || isButtonHovered ? 1 : 0.55)
        .frame(width: 22, height: 22)
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
        row(icon: "folder") {
          Text(model.displayPath)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
        }
        row(icon: "arrow.triangle.branch") {
          Text(model.branch ?? "(detached)")
            .lineLimit(1)
        }
        row(icon: "plusminus") {
          diffStats(model.diff)
        }
        if let agent = model.agent {
          row(icon: nil) {
            HStack(spacing: 5) {
              AgentLogoView(kind: agent, size: 12)
              Text(agent.displayName)
            }
          }
        }
      }
      .font(.system(size: 12))

      Divider()
      handOffButton(model)
    }
    .frame(minWidth: 190, alignment: .leading)
  }

  private func row<Content: View>(
    icon: String?,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 7) {
      Group {
        if let icon {
          Image(systemName: icon)
        } else {
          Color.clear
        }
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      // Fixed leading column so every row's text starts on the same x,
      // including the agent row whose glyph is a brand mark, not a symbol.
      .frame(width: 14, alignment: .center)
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
          .frame(width: 14, alignment: .center)
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
