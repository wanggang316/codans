import CodansCore
import SwiftUI

/// A run's attention message and the actions the machine offers for it,
/// shared by the Agents View popover and the Workflow Runs window so both
/// resolve a run the same way. `attention.actions` is rendered exactly as
/// given — order and membership are the machine's policy, never re-derived
/// here. Skip confirms first when it would end the run.
struct WorkflowAttentionView: View {
  enum Layout {
    /// One action per line — the popover is too narrow for provisional
    /// delivery's five actions in a row.
    case stacked
    /// Actions side by side, wrapping onto a second row when needed.
    case row
  }

  let session: WorkflowRunSession
  let engine: WorkflowEngine
  let attention: WorkflowAttention
  var layout: Layout = .stacked

  @State private var skipConfirmationMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(attention.message)
        .font(layout == .stacked ? .caption : .body)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      // The machine folds a provisional delivery's issues into its message;
      // repeating them below would say the same thing twice.
      let unlisted = attention.issues.filter { !attention.message.contains($0) }
      if !unlisted.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(unlisted, id: \.self) { issue in
            Text("• \(issue)")
              .font(layout == .stacked ? .caption2 : .callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      switch layout {
      case .stacked:
        VStack(alignment: .leading, spacing: 4) { actions }
      case .row:
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { actions }
          VStack(alignment: .leading, spacing: 6) { actions }
        }
      }
    }
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

  @ViewBuilder
  private var actions: some View {
    ForEach(attention.actions, id: \.self) { action in
      actionButton(action)
    }
  }

  @ViewBuilder
  private func actionButton(_ action: WorkflowUserAction) -> some View {
    let font: Font = layout == .stacked ? .caption : .body
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
      .fixedSize()
      .font(font)
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
      .font(font)
      .accessibilityIdentifier("agentState.workflow.\(action.accessibilitySuffix)")
    default:
      Button(action.displayLabel) {
        engine.resolve(runID: session.id, action: action, verdict: nil)
      }
      .buttonStyle(.bordered)
      .font(font)
      .accessibilityIdentifier("agentState.workflow.\(action.accessibilitySuffix)")
    }
  }
}
