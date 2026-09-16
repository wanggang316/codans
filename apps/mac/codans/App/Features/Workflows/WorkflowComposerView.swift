import CodansCore
import SwiftUI

struct WorkflowWorkspaceChoice: Identifiable {
  let id: WorktreeID
  let projectID: ProjectID
  let title: String
}

struct WorkflowPaneChoice: Identifiable {
  let id: PaneID
  let title: String
  let worktreeID: WorktreeID
}

struct WorkflowCreateDraft {
  let commandID: UUID
  let template: AgentWorkflowTemplate
  let title: String
  let input: String
  let workspaceID: WorktreeID
  let primaryProfileID: UUID?
  let secondaryProfileID: UUID?
  let sourcePaneID: PaneID?
}

enum WorkflowCreationError: LocalizedError {
  case unavailable
  var errorDescription: String? { "Workflow creation is unavailable in this window." }
}

@MainActor
struct WorkflowComposerView: View {
  let workspaces: [WorkflowWorkspaceChoice]
  let profiles: [AgentProfile]
  let panes: [WorkflowPaneChoice]
  let defaultWorkspaceID: WorktreeID?
  let onCreate: @MainActor (WorkflowCreateDraft) async throws -> UUID
  let onCreated: (UUID) -> Void
  let onCancel: () -> Void
  @State private var commandID = UUID()
  @State private var template: AgentWorkflowTemplate = .advisor
  @State private var title = ""
  @State private var input = ""
  @State private var workspaceID: WorktreeID?
  @State private var primaryProfileID: UUID?
  @State private var secondaryProfileID: UUID?
  @State private var sourcePaneID: PaneID?
  @State private var busy = false
  @State private var errorMessage: String?

  private var isHandoff: Bool { template == .handoff || template == .handoffSave }
  private var availableProfiles: [AgentProfile] { profiles.filter(\.isEnabled) }
  private var sourcePanes: [WorkflowPaneChoice] { panes.filter { $0.worktreeID == workspaceID } }
  private var canCreate: Bool {
    guard !busy, workspaces.contains(where: { $0.id == workspaceID }),
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    if isHandoff && !sourcePanes.contains(where: { $0.id == sourcePaneID }) { return false }
    if template != .handoffSave && !availableProfiles.contains(where: { $0.id == primaryProfileID }) { return false }
    return template != .committee || availableProfiles.contains(where: { $0.id == secondaryProfileID })
  }

  var body: some View {
    Form {
      Section {
        Picker("Workflow", selection: $template) {
          ForEach(AgentWorkflowTemplate.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField("Title", text: $title)
        Picker("Workspace", selection: $workspaceID) {
          Text("Choose a workspace").tag(nil as WorktreeID?)
          ForEach(workspaces) { Text($0.title).tag(Optional($0.id)) }
        }
        if workspaces.isEmpty { Text("Open a project workspace to create a workflow.").foregroundStyle(.secondary) }
      }
      Section(isHandoff ? "Briefing" : "Question") {
        TextEditor(text: $input).frame(minHeight: 140).font(.body)
          .accessibilityLabel(isHandoff ? "Briefing" : "Question")
        Text(
          isHandoff
            ? "Include the objective, current state, completed work, constraints, and next steps."
            : "Describe the question, relevant files, constraints, and the evidence you need."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Agents") {
        if isHandoff {
          Picker("Source pane", selection: $sourcePaneID) {
            Text("Choose a source pane").tag(nil as PaneID?)
            ForEach(sourcePanes) { Text($0.title).tag(Optional($0.id)) }
          }
        }
        if template != .handoffSave {
          profilePicker(
            template == .committee ? "First reviewer" : isHandoff ? "Receiver" : "Advisor", selection: $primaryProfileID
          )
          if availableProfiles.isEmpty {
            Text("Enable an agent profile in Settings before starting.").foregroundStyle(.secondary)
          }
        }
        if template == .committee {
          profilePicker("Second reviewer", selection: $secondaryProfileID)
          Text("Reviewers receive independent assignments before comparing their findings.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let errorMessage {
        Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
      }
      Section {
        HStack {
          Button("Cancel", action: onCancel).disabled(busy)
          Spacer()
          if busy { ProgressView().controlSize(.small) }
          Button(busy ? "Starting…" : "Start Workflow", action: submit)
            .buttonStyle(.borderedProminent).disabled(!canCreate)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("New Workflow")
    .disabled(busy)
    .onAppear {
      if workspaceID == nil { workspaceID = defaultWorkspaceID ?? workspaces.first?.id }
      if primaryProfileID == nil { primaryProfileID = availableProfiles.first?.id }
      if secondaryProfileID == nil {
        secondaryProfileID = availableProfiles.dropFirst().first?.id ?? availableProfiles.first?.id
      }
    }
    .onChange(of: workspaceID) { _, _ in sourcePaneID = nil }
  }

  private func profilePicker(_ title: String, selection: Binding<UUID?>) -> some View {
    Picker(title, selection: selection) {
      Text("Choose a profile").tag(nil as UUID?)
      ForEach(availableProfiles) { Text($0.displayName).tag(Optional($0.id)) }
    }
  }

  private func submit() {
    guard canCreate, let workspaceID else { return }
    let draft = WorkflowCreateDraft(
      commandID: commandID, template: template, title: title, input: input, workspaceID: workspaceID,
      primaryProfileID: template == .handoffSave ? nil : primaryProfileID,
      secondaryProfileID: template == .committee ? secondaryProfileID : nil,
      sourcePaneID: isHandoff ? sourcePaneID : nil)
    // Keep the submitted identity on failure, so retrying cannot launch a duplicate run.
    busy = true
    errorMessage = nil
    Task {
      do {
        let id = try await onCreate(draft)
        busy = false
        onCreated(id)
      } catch {
        busy = false
        errorMessage = error.localizedDescription
      }
    }
  }
}
