import AppKit
import CodansCore
import SwiftUI

/// Popover opened from a Workflows row in the AgentState panel: header,
/// step list, role panes, the attention action table when the run is
/// waiting on the user, and footer links. Styled after
/// `PullRequestPopover` — same width, spacing, and section rhythm.
///
/// A finished run renders the same sections minus attention and the
/// Cancel Run button (its `attention` is always nil and its status is
/// terminal, so those sections gate themselves off).
struct WorkflowRunPopoverView: View {
  let session: WorkflowRunSession
  let engine: WorkflowEngine
  let onFocusPane: (PaneID) -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      VStack(alignment: .leading, spacing: 10) {
        header(at: context.date)
        Divider()
        stepList
        if !roleRows.isEmpty {
          Divider()
          roleList
        }
        if let attention = session.attention {
          Divider()
          attentionSection(attention)
        }
        Divider()
        footer
      }
    }
    .frame(width: 340)
    .padding(12)
    .controlSize(.regular)
  }

  // MARK: - Header

  private func header(at now: Date) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(session.name)
          .font(.callout.weight(.semibold))
          .lineLimit(2)
        Spacer()
      }
      HStack(spacing: 6) {
        Text(session.stateName.replacingOccurrences(of: "_", with: " "))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("·")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(WorkflowRunRowView.elapsedText(session.elapsed(at: now)))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
  }

  // MARK: - Steps

  private var stepRows: [WorkflowRunDisplay.StepRow] {
    WorkflowRunDisplay.stepRows(for: session.run)
  }

  private var stepList: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Steps").font(.caption.weight(.semibold))
      ForEach(stepRows) { row in
        HStack(spacing: 6) {
          stepGlyph(row.status)
          Text(row.name)
            .font(.caption)
            .foregroundStyle(row.status == .pending ? .secondary : .primary)
            .lineLimit(1)
          Spacer()
        }
      }
    }
  }

  @ViewBuilder
  private func stepGlyph(_ status: WorkflowRunDisplay.StepStatus) -> some View {
    switch status {
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Done")
    case .current:
      Image(systemName: "circle.fill")
        .foregroundStyle(.blue)
        .font(.system(size: 8))
        .accessibilityLabel("Current step")
    case .pending:
      Image(systemName: "circle")
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Pending")
    case .skipped:
      Image(systemName: "circle.dashed")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Skipped")
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
        .accessibilityLabel("Failed")
    }
  }

  // MARK: - Roles

  private var roleRows: [WorkflowRunDisplay.RoleRow] {
    WorkflowRunDisplay.roleRows(for: session.run)
  }

  private var roleList: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Roles").font(.caption.weight(.semibold))
      ForEach(roleRows) { row in
        HStack(spacing: 6) {
          Text(row.name)
            .font(.caption)
            .foregroundStyle(.primary)
          Spacer()
          if let paneID = row.paneID {
            Button("Focus") { onFocusPane(paneID) }
              .buttonStyle(.link)
              .font(.caption)
              .accessibilityIdentifier("agentState.workflow.focusRole")
          } else {
            Text("not launched yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
  }

  // MARK: - Attention

  private func attentionSection(_ attention: WorkflowAttention) -> some View {
    WorkflowAttentionView(session: session, engine: engine, attention: attention, layout: .stacked)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 8) {
      Button("Open Log") {
        NSWorkspace.shared.open(session.store.logURL)
      }
      .buttonStyle(.link)
      .font(.caption)
      .accessibilityIdentifier("agentState.workflow.openLog")
      Button("Reveal Run Folder") {
        NSWorkspace.shared.activateFileViewerSelecting([session.store.runDirectory])
      }
      .buttonStyle(.link)
      .font(.caption)
      .accessibilityIdentifier("agentState.workflow.revealRunFolder")
      Spacer()
      if !session.run.status.isTerminal {
        Button("Cancel Run", role: .destructive) {
          engine.cancel(runID: session.id)
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .accessibilityIdentifier("agentState.workflow.cancelRun")
      }
    }
  }
}
