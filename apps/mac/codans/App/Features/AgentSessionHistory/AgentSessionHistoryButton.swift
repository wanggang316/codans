import CodansCore
import SwiftUI

/// Tab-bar trailing accessory for the Agent Session History popover — a
/// clock glyph to the right of the `+` (new tab) button. Tapping lists
/// every agent session the installed agent CLIs recorded against the
/// current worktree in their own local stores; a row's play button reopens
/// that session at the placement chosen in the popover's bottom toolbar. Chrome mirrors the sibling `+` / split
/// accessories (22×22 circular hover) so the cluster reads as one family.
struct AgentSessionHistoryButton: View {
  /// Worktree path the popover scans against; also the cwd the resume
  /// tab spawns in. A remote path string for Server projects.
  let worktreePath: String
  /// SSH host for a Server-project worktree, `nil` for local. Routes the
  /// popover's scan to the host's session stores over SSH; resume needs no
  /// routing — the command is typed into a pane whose shell already runs
  /// on the host.
  var remoteHost: RemoteHost?
  /// The worktree's focused pane as the placement picker sees it.
  let resumeContext: AgentResumePlacement.Context
  /// Row play-button callback. `TabBarView` maps this to
  /// `TabBarFeature.resumeAgentSessionTapped`, which runs the resume.
  let onResume: (AgentSessionSummary, AgentResumePlacement) -> Void

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
    .agentSessionHistoryPopover(
      isPresented: $popoverShown,
      worktreePath: worktreePath,
      remoteHost: remoteHost,
      resumeContext: resumeContext,
      onResume: onResume
    )
  }
}

extension View {
  /// Anchors the Agent Session History popover to this view. Shared by the
  /// tab-bar clock accessory and the empty-terminal "Resume Session" button
  /// so both list the same sessions and resume the same way. The popover
  /// dismisses itself before it calls `onResume`. `resumeContext` is the
  /// worktree's focused pane; the empty-terminal entry passes
  /// `.noFocusedPane`.
  func agentSessionHistoryPopover(
    isPresented: Binding<Bool>,
    worktreePath: String,
    remoteHost: RemoteHost?,
    resumeContext: AgentResumePlacement.Context,
    onResume: @escaping (AgentSessionSummary, AgentResumePlacement) -> Void
  ) -> some View {
    popover(isPresented: isPresented, arrowEdge: .bottom) {
      AgentSessionHistoryPopover(
        worktreePath: worktreePath,
        remoteHost: remoteHost,
        resumeContext: resumeContext,
        onResume: { session, placement in
          isPresented.wrappedValue = false
          onResume(session, placement)
        },
        onClose: { isPresented.wrappedValue = false }
      )
      .frame(minWidth: 340, idealWidth: 400, maxWidth: 520, minHeight: 180, idealHeight: 420)
    }
  }
}

/// Popover body: header + agent-grouped session list, newest agent first,
/// sessions newest-first within each group, and a bottom toolbar with the
/// resume placement. Esc routing follows the
/// `InboxPopoverContent` pattern (NSPopover doesn't dismiss on Esc while
/// focus sits on the anchor toolbar button).
private struct AgentSessionHistoryPopover: View {
  let worktreePath: String
  var remoteHost: RemoteHost?
  let resumeContext: AgentResumePlacement.Context
  let onResume: (AgentSessionSummary, AgentResumePlacement) -> Void
  let onClose: () -> Void

  /// nil while the initial scan runs. The scan stats and prefix-reads
  /// dozens of session files, so it runs on a detached task instead of
  /// the main actor the popover opens on.
  @State private var groups: [AgentSessionGroup]?
  @FocusState private var focused: Bool
  /// Read once per open. A remembered In Place that the focused pane cannot
  /// take shows as New Tab without overwriting what is remembered; only a
  /// pick in the toolbar writes it back.
  @State private var placement: AgentResumePlacement

  init(
    worktreePath: String,
    remoteHost: RemoteHost?,
    resumeContext: AgentResumePlacement.Context,
    onResume: @escaping (AgentSessionSummary, AgentResumePlacement) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.worktreePath = worktreePath
    self.remoteHost = remoteHost
    self.resumeContext = resumeContext
    self.onResume = onResume
    self.onClose = onClose
    _placement = State(initialValue: AgentResumePlacementPersistence.load().shown(in: resumeContext))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      toolbar
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
      // Server-project worktrees keep their agent session stores in the
      // HOST's home — scan over SSH; local worktrees read the local stores
      // on a detached task (dozens of file stats + prefix reads).
      if let host = remoteHost {
        groups = await RemoteAgentSessionHistoryScanner.scan(host: host, worktreePath: path)
      } else {
        groups = await Task.detached(priority: .userInitiated) {
          AgentSessionHistoryScanner.scan(worktreePath: path)
        }.value
      }
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
                AgentSessionRowView(
                  session: session,
                  resumeHelp: Self.resumeHelp(for: placement.resolved(in: resumeContext)),
                  onResume: { onResume(session, placement) })
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

  /// Where the row play button resumes: a target menu, and for a split a
  /// second menu for the side. Same pair and look as the Hand Off panel,
  /// plus "In Place", which is disabled while the focused pane runs an agent
  /// or there is no focused pane.
  private var toolbar: some View {
    HStack(spacing: 8) {
      Picker("Resume in", selection: targetSelection) {
        Text("New Tab").tag(ScriptTarget.newTab)
        Text("In Place").tag(ScriptTarget.focused)
          .selectionDisabled(!resumeContext.allowsInPlace)
        Text("New Split").tag(ScriptTarget.split)
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      .help("Where a resumed session opens")
      .accessibilityIdentifier("agentSessions.placement")

      if case .split = placement {
        Picker("Split Direction", selection: directionSelection) {
          Text("Right").tag(ScriptSplitDirection.right)
          Text("Down").tag(ScriptSplitDirection.down)
          Text("Left").tag(ScriptSplitDirection.left)
          Text("Up").tag(ScriptSplitDirection.up)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Which side of the focused pane the split opens on")
        .accessibilityIdentifier("agentSessions.placement.direction")
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// Switching to New Split from another placement starts on the right.
  private var targetSelection: Binding<ScriptTarget> {
    Binding(
      get: { placement.target },
      set: { target in
        switch target {
        case .newTab: choose(.newTab)
        case .focused: choose(.inPlace)
        case .split: choose(.split(placement.direction ?? .right))
        }
      }
    )
  }

  private var directionSelection: Binding<ScriptSplitDirection> {
    Binding(
      get: { placement.direction ?? .right },
      set: { choose(.split($0)) }
    )
  }

  private func choose(_ newPlacement: AgentResumePlacement) {
    guard newPlacement != placement else { return }
    placement = newPlacement
    AgentResumePlacementPersistence.save(newPlacement)
  }

  static func resumeHelp(for placement: AgentResumePlacement) -> String {
    switch placement {
    case .newTab: return "Resume in a new tab"
    case .inPlace: return "Resume in the focused pane"
    case .split: return "Resume in a new split"
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
  let resumeHelp: String
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
      .help(resumeHelp)
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
