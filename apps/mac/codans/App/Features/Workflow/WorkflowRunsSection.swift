import CodansCore
import SwiftUI

/// "Workflows" rows under the agent list in the AgentState panel: one row
/// per active run — name, current step, state, elapsed time — followed by
/// a dimmed strip of recently finished runs. A row waiting on the user
/// carries an orange dot and its attention message as the tooltip.
/// Clicking any row opens `WorkflowRunPopoverView`; a finished row's
/// popover renders the same sections minus attention and Cancel Run.
struct WorkflowRunsSection: View {
  /// Recently finished runs shown below the active ones, oldest first as
  /// the engine keeps them; capped so the panel doesn't grow unbounded
  /// across a long session.
  static let maxFinishedRowsShown = 5

  let engine: WorkflowEngine
  let onTapRun: (PaneID) -> Void

  var body: some View {
    let runs = engine.activeRuns
    let finished = Array(engine.finishedRuns.suffix(Self.maxFinishedRowsShown).reversed())
    if !runs.isEmpty || !finished.isEmpty {
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
          WorkflowRunRowView(session: session, engine: engine, onTapRun: onTapRun, isFinished: false)
        }
        ForEach(finished, id: \.id) { session in
          WorkflowRunRowView(session: session, engine: engine, onTapRun: onTapRun, isFinished: true)
        }
      }
      .accessibilityIdentifier("agentState.sidebarPanel.workflows")
    }
  }
}

struct WorkflowRunRowView: View {
  let session: WorkflowRunSession
  let engine: WorkflowEngine
  let onTapRun: (PaneID) -> Void
  /// Dims the row and opens the popover without any action affordances —
  /// its `session.attention` is always nil and its status terminal, so
  /// the popover's own sections gate those off; this only drives the row's
  /// visual treatment.
  let isFinished: Bool

  @State private var isHovering = false
  @State private var isPopoverPresented = false

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
      .opacity(isFinished ? 0.55 : 1)
      .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
      .onTapGesture { isPopoverPresented = true }
      .accessibilityAddTraits(.isButton)
      .help(session.attention?.message ?? "\(session.name) · \(session.stateName)")
      .accessibilityIdentifier("agentState.sidebarPanel.workflowRow")
      .popover(isPresented: $isPopoverPresented, arrowEdge: .trailing) {
        WorkflowRunPopoverView(session: session, engine: engine, onFocusPane: onTapRun)
      }
    }
  }

  private var subtitle: String {
    var parts: [String] = []
    if let step = session.currentStepName { parts.append(step) }
    parts.append(isFinished ? session.stateName : (session.attention == nil ? "running" : "needs attention"))
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
