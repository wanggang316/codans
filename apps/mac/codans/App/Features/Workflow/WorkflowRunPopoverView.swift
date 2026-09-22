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

  @State private var skipConfirmationMessage: String?

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
    .confirmationDialog(
      "Skip this step?",
      isPresented: Binding(
        get: { skipConfirmationMessage != nil },
        set: { if !$0 { skipConfirmationMessage = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Skip", role: .destructive) {
        skipConfirmationMessage = nil
        engine.resolve(runID: session.id, action: .skip, verdict: nil)
      }
      .accessibilityIdentifier("agentState.workflow.skip.confirm")
      Button("Cancel", role: .cancel) { skipConfirmationMessage = nil }
    } message: {
      Text(skipConfirmationMessage ?? "")
    }
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
    VStack(alignment: .leading, spacing: 6) {
      Text(attention.message)
        .font(.caption)
        .foregroundStyle(.primary)
      // The machine folds a provisional delivery's issues into its message;
      // repeating them below would say the same thing twice.
      let unlisted = attention.issues.filter { !attention.message.contains($0) }
      if !unlisted.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(unlisted, id: \.self) { issue in
            Text("• \(issue)")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      // `attention.actions` is rendered exactly as given — order and
      // membership are the machine's policy, never re-derived here.
      // Stacked (not a row) because the widest table — provisional
      // delivery's five actions — would overflow the popover's width.
      VStack(alignment: .leading, spacing: 4) {
        ForEach(attention.actions, id: \.self) { action in
          actionButton(action)
        }
      }
    }
  }

  @ViewBuilder
  private func actionButton(_ action: WorkflowUserAction) -> some View {
    switch action {
    case .acceptWithVerdict:
      let verdicts = WorkflowRunDisplay.verdictOptions(for: session.run)
      Menu(action.displayLabel) {
        ForEach(verdicts, id: \.self) { verdict in
          Button(verdict) {
            engine.resolve(runID: session.id, action: .acceptWithVerdict, verdict: verdict)
          }
        }
      }
      .menuStyle(.button)
      .buttonStyle(.bordered)
      .font(.caption)
      .accessibilityIdentifier("agentState.workflow.\(action.accessibilitySuffix)")
    case .skip:
      Button(action.displayLabel) {
        let message = WorkflowRunDisplay.skipConfirmationMessage(machine: session.machine)
        if let message {
          skipConfirmationMessage = message
        } else {
          engine.resolve(runID: session.id, action: .skip, verdict: nil)
        }
      }
      .buttonStyle(.bordered)
      .font(.caption)
      .accessibilityIdentifier("agentState.workflow.\(action.accessibilitySuffix)")
    default:
      Button(action.displayLabel) {
        engine.resolve(runID: session.id, action: action, verdict: nil)
      }
      .buttonStyle(.bordered)
      .font(.caption)
      .accessibilityIdentifier("agentState.workflow.\(action.accessibilitySuffix)")
    }
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
