import CodansCore
import SwiftUI

@MainActor
struct WorkflowRunsView: View {
  let store: AgentWorkflowStore
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
        if let run = selectedRun {
          runDetail(run)
        } else if store.runs.isEmpty {
          ContentUnavailableView {
            Label("No Workflows Yet", systemImage: "list.bullet.rectangle")
          } description: {
            VStack(spacing: 8) {
              Text("Create a workflow from the terminal to track assignments and their delivered results.")
              Text(
                "\(CLIInvocation.commandName) workflow create --template advisor --title 'Review a change' --input 'Review the current diff'"
              )
              .font(.caption.monospaced())
              .textSelection(.enabled)
            }
          }
        } else {
          ContentUnavailableView("Select a Workflow", systemImage: "list.bullet.rectangle")
        }
      }
    }
    .frame(minWidth: 760, minHeight: 480)
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
          Text(run.id.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
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
        GroupBox("Input") {
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
        Text(step.id).font(.caption.monospaced()).foregroundStyle(.secondary)
        if !step.dependencies.isEmpty {
          Text("Depends on: \(step.dependencies.joined(separator: ", "))")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(run.attempts.filter { $0.stepID == step.id }) { attempt in
          DisclosureGroup("Result · \(attemptStatus(attempt.status))") {
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
