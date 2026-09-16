import CodansCore
import SwiftUI

@MainActor
struct WorkflowRunsView: View {
  let store: AgentWorkflowStore
  var allowsCreation = true
  var workspaces: [WorkflowWorkspaceChoice] = []
  var profiles: [AgentProfile] = []
  var panes: [WorkflowPaneChoice] = []
  var defaultWorkspaceID: WorktreeID?
  var creationRequest: UUID?
  var onCreate: @MainActor (WorkflowCreateDraft) async throws -> UUID = { _ in throw WorkflowCreationError.unavailable }
  var onOpenPane: @MainActor (String) -> Void = { _ in }
  var onDisposition: (@MainActor (UUID, String) throws -> Void)?
  var onRecordResult: (@MainActor (UUID, String, String) throws -> Void)?
  @State private var composing = false
  @State private var dispositionReason = ""
  @State private var dispositionChoice = "Adopt"
  @State private var dispositionError: String?
  @State private var selection: UUID?
  @State private var cancellationError: String?

  private var selectedRun: AgentWorkflowRun? {
    store.runs.first { $0.id == selection }
  }

  var body: some View {
    VStack(spacing: 0) {
      if !store.issues.isEmpty {
        DisclosureGroup("Workflow storage needs attention (\(store.issues.count))") {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(store.issues.enumerated()), id: \.offset) { _, issue in
                Text(issue).textSelection(.enabled)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 120)
        }
        .foregroundStyle(.orange)
        .padding()
        Divider()
      }
      NavigationSplitView {
        List(store.runs, selection: $selection) { run in
          VStack(alignment: .leading, spacing: 4) {
            Text(run.title).font(.headline)
            Text("\(run.template.title) · \(runStatus(run.status))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 3)
          .tag(run.id)
        }
        .navigationTitle("Workflows")
        .navigationSplitViewColumnWidth(min: 220, ideal: 270)
      } detail: {
        if composing {
          WorkflowComposerView(
            workspaces: workspaces, profiles: profiles, panes: panes,
            defaultWorkspaceID: defaultWorkspaceID, onCreate: onCreate,
            onCreated: {
              selection = $0
              composing = false
            }, onCancel: { composing = false })
        } else if let run = selectedRun {
          runDetail(run)
        } else if store.runs.isEmpty {
          ContentUnavailableView {
            Label("No Workflows Yet", systemImage: "list.bullet.rectangle")
          } description: {
            Text("Ask an advisor, compare independent reviews, or hand a task to another agent.")
          } actions: {
            if allowsCreation {
              Button("New Workflow") { composing = true }
                .buttonStyle(.borderedProminent)
            }
          }
        } else {
          ContentUnavailableView("Select a Workflow", systemImage: "list.bullet.rectangle")
        }
      }
    }
    .frame(minWidth: 760, minHeight: 480)
    .toolbar {
      if allowsCreation {
        Button {
          composing = true
        } label: {
          Label("New Workflow", systemImage: "plus")
        }
      }
    }
    .onChange(of: creationRequest) { _, request in if request != nil { composing = true } }
    .onAppear { if creationRequest != nil { composing = true } }
    .onChange(of: selection) { _, _ in
      dispositionReason = ""
      dispositionError = nil
    }
    .alert(
      "Could Not Cancel Workflow",
      isPresented: Binding(
        get: { cancellationError != nil },
        set: { if !$0 { cancellationError = nil } }
      )
    ) {
      Button("OK") { cancellationError = nil }
    } message: {
      Text(cancellationError ?? "")
    }
  }

  private func runDetail(_ run: AgentWorkflowRun) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 6) {
          Text(run.title).font(.title2.bold())
          Text("\(run.template.title) · \(runStatus(run.status))")
            .foregroundStyle(.secondary)
          Text(run.updatedAt, format: .dateTime.year().month().day().hour().minute())
            .font(.caption).foregroundStyle(.secondary)
          if run.status == .succeeded {
            Text("All steps have delivered results. This does not verify the underlying task is complete.")
              .font(.callout).foregroundStyle(.secondary)
          } else if run.status == .cancelled || run.status == .interrupted {
            Text("External agents may still be working. Check their panes before assigning replacement work.")
              .font(.callout).foregroundStyle(.secondary)
          }
        }
        if let issue = run.events.last(where: { $0.type.hasSuffix(".failed") || $0.type.hasSuffix(".unknown") }) {
          Label(issue.message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
        if run.status == .running {
          dispatchStatus(run)
        }
        if let attempt = run.currentAttempt {
          HStack {
            Label("Waiting for the agent’s result", systemImage: "hourglass")
            Spacer()
            Button("Open Agent") { onOpenPane(attempt.paneID) }
          }
        }
        if let report = primaryReport(run) {
          GroupBox(run.template == .advisor ? "Advice" : "Report") {
            Text(report).frame(maxWidth: .infinity, alignment: .leading).padding(4)
          }
        }
        if run.template == .advisor, run.readySteps.contains(where: { $0.id == "disposition" }), onDisposition != nil {
          dispositionForm(run)
        }
        DisclosureGroup("Original request") {
          Text(run.input.isEmpty ? "No input provided." : run.input)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("Steps").font(.headline)
          ForEach(run.steps) { step in
            stepDetail(step, run: run)
          }
        }
        VStack(alignment: .leading, spacing: 12) {
          Text("History").font(.headline)
          ForEach(run.events, id: \.sequence) { event in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text("#\(event.sequence) · \(event.type)").font(.caption.monospaced())
                Spacer()
                Text(event.date, format: .dateTime.month().day().hour().minute().second())
                  .font(.caption).foregroundStyle(.secondary)
              }
              Text(event.message)
            }
            Divider()
          }
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
    }
    .toolbar {
      if run.status == .running {
        Button("Cancel Workflow", role: .destructive) {
          do { _ = try store.cancel(run.id) } catch { cancellationError = error.localizedDescription }
        }
        .help("Stop accepting results and scheduling steps. External agents are not stopped.")
      }
    }
  }

  private func stepDetail(_ step: AgentWorkflowStep, run: AgentWorkflowRun) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(step.title).font(.headline)
          Spacer()
          Text(stepStatus(step, run: run)).font(.caption).foregroundStyle(.secondary)
        }
        if !step.dependencies.isEmpty {
          Text(
            "After: \(step.dependencies.map { dependency in run.steps.first(where: { $0.id == dependency })?.title ?? dependency }.joined(separator: ", "))"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if canRecordResult(step, run: run), let onRecordResult {
          WorkflowManualResultForm { content in
            try onRecordResult(run.id, step.id, content)
          }
          .id("\(run.id)-\(step.id)")
        }
        ForEach(run.attempts.filter { $0.stepID == step.id }) { attempt in
          if attempt.status == .active {
            Button("Open Agent") { onOpenPane(attempt.paneID) }
          }
          DisclosureGroup("Details · \(attemptStatus(attempt.status))") {
            VStack(alignment: .leading, spacing: 8) {
              Text("Attempt: \(attempt.id.uuidString)")
              Text("Pane: \(attempt.paneID)")
              if let date = attempt.deliveredAt {
                Text(date, format: .dateTime.year().month().day().hour().minute().second())
              }
              Text(attempt.content ?? "No result delivered.")
                .font(.body)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
  }

  private func canRecordResult(_ step: AgentWorkflowStep, run: AgentWorkflowRun) -> Bool {
    guard run.status == .running,
      (run.template == .advisor && step.id == "advice") || run.template == .committee
    else { return false }
    return step.status == .active || run.readySteps.contains(where: { $0.id == step.id })
  }

  @ViewBuilder
  private func dispatchStatus(_ run: AgentWorkflowRun) -> some View {
    if let execution = store.records[run.id]?.execution {
      ForEach(run.steps.filter { $0.status != .accepted && $0.status != .revoked }) { step in
        if let dispatch = execution.dispatches[step.id] {
          HStack(alignment: .top) {
            Label {
              VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(
                  dispatch.message
                    ?? (dispatch.status == .launching
                      ? "Starting agent…"
                      : dispatch.status == .attention ? "Needs attention" : "Assignment sent; waiting for a result")
                )
                .font(.callout)
              }
            } icon: {
              Image(systemName: dispatch.status == .attention ? "exclamationmark.triangle" : "hourglass")
                .accessibilityHidden(true)
            }
            Spacer()
            if let paneID = dispatch.paneID {
              Button("Open Agent") { onOpenPane(paneID) }
            }
          }
        }
      }
    }
  }

  private func primaryReport(_ run: AgentWorkflowRun) -> String? {
    let step = run.template == .advisor ? "advice" : run.template == .committee ? "synthesis" : "packet"
    return run.attempts.last { $0.stepID == step && $0.status == .accepted }?.content
  }

  private func dispositionForm(_ run: AgentWorkflowRun) -> some View {
    GroupBox("Your decision") {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Decision", selection: $dispositionChoice) {
          ForEach(["Adopt", "Need more evidence", "Reject"], id: \.self) { Text($0).tag($0) }
        }
        TextField("Reason", text: $dispositionReason, axis: .vertical).lineLimit(2...5)
        if let dispositionError { Text(dispositionError).foregroundStyle(.red) }
        Button("Record Decision") {
          do {
            try onDisposition?(run.id, "Decision: \(dispositionChoice)\nReason: \(dispositionReason)")
            dispositionError = nil
          } catch { dispositionError = error.localizedDescription }
        }
        .disabled(dispositionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(4)
    }
  }

  private func runStatus(_ status: AgentWorkflowRun.Status) -> String {
    switch status {
    case .running: "In progress"
    case .succeeded: "Results received"
    case .cancelled: "Cancelled"
    case .interrupted: "Interrupted"
    }
  }

  private func stepStatus(_ step: AgentWorkflowStep, run: AgentWorkflowRun) -> String {
    switch step.status {
    case .pending: run.readySteps.contains(where: { $0.id == step.id }) ? "Ready to claim" : "Waiting"
    case .active: "Awaiting delivery"
    case .accepted: "Result accepted"
    case .revoked: "Stopped accepting results"
    }
  }

  private func attemptStatus(_ status: AgentWorkflowAttempt.Status) -> String {
    switch status {
    case .active: "Awaiting delivery"
    case .accepted: "Accepted"
    case .revoked: "Revoked"
    }
  }
}

@MainActor
private struct WorkflowManualResultForm: View {
  let submit: (String) throws -> Void
  @State private var content = ""
  @State private var errorMessage: String?

  var body: some View {
    DisclosureGroup("Record Result Manually") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "Paste the agent’s result after reviewing it. This records your submission and lets the next step proceed; it does not stop the agent."
        )
        .font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $content)
          .font(.body).frame(minHeight: 120)
          .accessibilityLabel("Manually recorded result")
        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
        }
        Button("Record Result") {
          do {
            try submit(content)
            errorMessage = nil
          } catch { errorMessage = error.localizedDescription }
        }
        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(.top, 6)
    }
  }
}
