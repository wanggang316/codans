import CodansCore
import SwiftUI

/// Tab-bar trailing accessory for the Agent Session History popover — a
/// clock glyph to the right of the `+` (new tab) button. Tapping lists
/// every agent session the installed agent CLIs recorded against the
/// current worktree in their own local stores; a row's play button reopens
/// that session in a fresh tab. Chrome mirrors the sibling `+` / split
/// accessories (22×22 circular hover) so the cluster reads as one family.
struct AgentSessionHistoryButton: View {
  /// Worktree path the popover scans against; also the cwd the resume
  /// tab spawns in.
  let worktreePath: String
  /// Row play-button callback. `TabBarView` maps this to
  /// `TabBarFeature.resumeAgentSessionTapped`, which spawns the resume tab.
  let onResume: (AgentSessionSummary) -> Void

  @State private var popoverShown = false
  @State private var isHovering = false

  var body: some View {
    Button(
      action: { popoverShown.toggle() },
      label: {
        Image(systemName: "clock.arrow.circlepath")
          // Decorative — the button's accessibilityLabel below names the
          // control; announcing the symbol too would double-speak it.
          .accessibilityHidden(true)
          .frame(width: 22, height: 22)
          .background(
            Circle()
              .fill(isHovering ? TabBarColors.hoverBackground : .clear)
          )
          .contentShape(Circle())
      }
    )
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help("Agent Session History")
    .accessibilityLabel("Agent session history")
    .popover(isPresented: $popoverShown, arrowEdge: .bottom) {
      AgentSessionHistoryPopover(
        worktreePath: worktreePath,
        onResume: { session in
          popoverShown = false
          onResume(session)
        },
        onClose: { popoverShown = false }
      )
      .frame(minWidth: 340, idealWidth: 400, maxWidth: 520, minHeight: 180, idealHeight: 420)
    }
  }
}

/// Popover body: header + agent-grouped session list, newest agent first,
/// sessions newest-first within each group. Esc routing follows the
/// `InboxPopoverContent` pattern (NSPopover doesn't dismiss on Esc while
/// focus sits on the anchor toolbar button).
private struct AgentSessionHistoryPopover: View {
  let worktreePath: String
  let onResume: (AgentSessionSummary) -> Void
  let onClose: () -> Void

  /// nil while the initial scan runs. The scan stats and prefix-reads
  /// dozens of session files, so it runs on a detached task instead of
  /// the main actor the popover opens on.
  @State private var groups: [AgentSessionGroup]?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
    }
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onAppear { focused = true }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
    .task {
      let path = worktreePath
      groups = await Task.detached(priority: .userInitiated) {
        AgentSessionHistoryScanner.scan(worktreePath: path)
      }.value
    }
  }

  private var header: some View {
    HStack {
      Text("Agent Sessions")
        .font(.callout.weight(.semibold))
      Spacer()
      if let count = groups?.reduce(0, { $0 + $1.sessions.count }), count > 0 {
        Text("\(count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var content: some View {
    if let groups {
      if groups.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
              sectionHeader(group)
              ForEach(group.sessions) { session in
                AgentSessionRowView(session: session, onResume: { onResume(session) })
                Divider()
              }
            }
          }
        }
      }
    } else {
      loadingState
    }
  }

  private func sectionHeader(_ group: AgentSessionGroup) -> some View {
    Text(group.agent.displayName)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.top, 10)
      .padding(.bottom, 4)
  }

  private var loadingState: some View {
    ProgressView()
      .controlSize(.small)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(24)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.title)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No agent sessions for this worktree")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

private struct AgentSessionRowView: View {
  let session: AgentSessionSummary
  let onResume: () -> Void

  /// Allocated once for the popover lifetime — a fresh
  /// `RelativeDateTimeFormatter` per row would spin up a CFLocale,
  /// calendar, and ICU context on every redraw.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  @State private var isHovering = false

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      AgentLogoView(kind: session.agent, size: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(session.title)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        HStack(spacing: 6) {
          Text(relativeAge)
          Text("·")
          Text(session.shortSessionID)
            .monospaced()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onResume) {
        Image(systemName: "play.fill")
          .font(.footnote)
          .foregroundStyle(isHovering ? Color.primary : Color.secondary)
          .frame(width: 24, height: 24)
          .background(Circle().fill(Color.primary.opacity(isHovering ? 0.10 : 0.06)))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Resume in a new tab")
      .accessibilityLabel("Resume session")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .background(isHovering ? Color.gray.opacity(0.08) : Color.clear)
    .onHover { isHovering = $0 }
    .help(session.title)
  }

  private var relativeAge: String {
    Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date())
  }
}
