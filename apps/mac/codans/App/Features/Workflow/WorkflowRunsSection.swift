import CodansCore
import SwiftUI

/// Read-only "Workflows" rows under the agent list in the AgentState
/// panel: one row per active run — name, current step, state, elapsed
/// time. A run waiting on the user carries an orange dot and its
/// attention message as the tooltip. Clicking a row focuses the pane the
/// run is about; attention actions stay on the CLI for now.
struct WorkflowRunsSection: View {
  let engine: WorkflowEngine
  let onTapRun: (PaneID) -> Void

  var body: some View {
    let runs = engine.activeRuns
    if !runs.isEmpty {
      VStack(spacing: 0) {
        Divider()
          .padding(.vertical, 4)
        HStack {
          Text("Workflows")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        ForEach(runs, id: \.id) { session in
          WorkflowRunRowView(session: session) {
            if let paneID = session.focusPaneID { onTapRun(paneID) }
          }
        }
      }
      .accessibilityIdentifier("agentState.sidebarPanel.workflows")
    }
  }
}

struct WorkflowRunRowView: View {
  let session: WorkflowRunSession
  let onTap: () -> Void

  @State private var isHovering = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 8) {
        indicator
        VStack(alignment: .leading, spacing: 1) {
          Text(session.name)
            .font(.callout)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Text(Self.elapsedText(session.elapsed(at: context.date)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
      .onTapGesture(perform: onTap)
      .accessibilityAddTraits(.isButton)
      .help(session.attention?.message ?? "\(session.name) · \(session.stateName)")
      .accessibilityIdentifier("agentState.sidebarPanel.workflowRow")
    }
  }

  private var subtitle: String {
    var parts: [String] = []
    if let step = session.currentStepName { parts.append(step) }
    parts.append(session.attention == nil ? "running" : "needs attention")
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private var indicator: some View {
    if session.attention != nil {
      Circle()
        .fill(Color.orange)
        .frame(width: 8, height: 8)
        .accessibilityLabel("Needs attention")
    } else {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
  }

  static func elapsedText(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
    return String(format: "%d:%02d", minutes, seconds)
  }
}
