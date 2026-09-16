import CodansCore
import SwiftUI

@MainActor
struct WorkflowToolbarViewV2: View {
  let appState: AppState
  @State private var startingEntry: WorkflowCatalogV2.Entry?
  @State private var showingExecution = false
  @State private var startedFromForm = false
  @State private var showingHistory = false
  @State private var historyPinned = false
  @State private var hoveringButton = false
  @State private var hoveringHistory = false
  @State private var closeTask: Task<Void, Never>?
  @State private var selectedHistoryID: UUID?

  private var runnableEntries: [WorkflowCatalogV2.Entry] {
    appState.workflowCatalogV2.entries.filter { $0.definition != nil && $0.error == nil }
  }

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        if runnableEntries.isEmpty { Text("No valid workflow definitions") }
        ForEach(runnableEntries) { entry in
          Button(entry.name) { startingEntry = entry }
        }
        if let id = appState.workflowPresentedRunID, let run = appState.workflowServiceV2.run(id) {
          Divider()
          Button("\(WorkflowRunPresentationV2.status(run.status)): \(run.title)") {
            showingExecution = true
          }
        }
        Divider()
        Button("Refresh Definitions") { appState.workflowCatalogV2.reload() }
      } label: {
        Label("Run Workflow", systemImage: "point.3.connected.trianglepath.dotted")
      }
      .accessibilityLabel("Run Workflow")
      .help("Run a workflow")
      .popover(isPresented: $showingExecution) {
        executionPanel
      }
      Button {
        historyPinned.toggle()
        showingHistory = historyPinned
      } label: {
        Label("Workflow History", systemImage: "clock.arrow.circlepath")
      }
      .accessibilityLabel("Workflow History")
      .help("Workflow History. Hover to preview or click to keep open.")
      .onHover {
        hoveringButton = $0
        updateHistoryHover()
      }
      .popover(isPresented: $showingHistory) {
        historyPanel.onHover {
          hoveringHistory = $0
          updateHistoryHover()
        }
      }
    }
    .accessibilityElement(children: .contain)
    .onAppear { appState.workflowCatalogV2.reload() }
    .onDisappear { closeTask?.cancel() }
    .onChange(of: showingHistory) { _, visible in
      if !visible {
        historyPinned = false
        hoveringHistory = false
      }
    }
    .onChange(of: appState.workflowPresentedRunID) { _, id in
      if id != nil && startingEntry == nil { showingExecution = true }
    }
    .sheet(
      item: $startingEntry,
      onDismiss: {
        if startedFromForm {
          showingExecution = true
          startedFromForm = false
        }
      },
      content: { entry in
        if let definition = entry.definition {
          WorkflowRunFormViewV2(
            definition: definition, source: entry.source,
            profiles: appState.settingsStore.settings.agents.enabledProfiles,
            panes: appState.workflowAgentPanesV2, workspaces: appState.workflowWorkspaces,
            onStart: {
              try appState.startWorkflowV2(
                definition: $0, source: $1, title: $2, inputs: $3, selections: $4)
            }, onCancel: { startingEntry = nil },
            onStarted: { id in
              startedFromForm = true
              appState.workflowPresentedRunID = id
              startingEntry = nil
            })
        }
      })
  }

  private var executionPanel: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Current Workflow").font(.headline)
        Spacer()
        Button("Return to Terminal") { showingExecution = false }
      }.padding(12)
      Divider()
      if let id = appState.workflowPresentedRunID, let run = appState.workflowServiceV2.run(id) {
        WorkflowRunDetailViewV2(run: run, service: appState.workflowServiceV2, onOpenPane: openPane)
          .id(id)
      }
    }.frame(width: 620, height: 560)
  }

  private var historyPanel: some View {
    VStack(spacing: 0) {
      HStack {
        if selectedHistoryID != nil {
          Button("Back", systemImage: "chevron.left") {
            selectedHistoryID = nil
            historyPinned = true
          }
        }
        Text("Workflow History").font(.headline)
        Spacer()
        Button("Close") { showingHistory = false }
      }.padding(12)
      Divider()
      if let id = selectedHistoryID, let run = appState.workflowServiceV2.run(id) {
        WorkflowRunDetailViewV2(run: run, service: appState.workflowServiceV2, onOpenPane: openPane)
          .id(id)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(appState.workflowServiceV2.runs) { run in
              Button {
                historyPinned = true
                selectedHistoryID = run.id
              } label: {
                HStack(spacing: 12) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(.headline)
                    Text(WorkflowRunPresentationV2.status(run.status)).font(.caption)
                      .foregroundStyle(.secondary)
                    Text(run.createdAt, style: .relative).font(.caption2).foregroundStyle(
                      .secondary)
                  }
                  Spacer(minLength: 12)
                  Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Open workflow run \(run.title)")
              .accessibilityValue(WorkflowRunPresentationV2.status(run.status))
              Divider().padding(.horizontal, 16)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityLabel("Workflow Run History")
        if appState.workflowServiceV2.runs.isEmpty {
          Text("No workflow runs yet.").foregroundStyle(.secondary).padding()
        }
      }
    }.frame(width: 620, height: 560)
  }

  private func updateHistoryHover() {
    closeTask?.cancel()
    if hoveringButton || hoveringHistory {
      showingHistory = true
    } else if !historyPinned {
      closeTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(180))
        if !Task.isCancelled && !historyPinned { showingHistory = false }
      }
    }
  }

  private func openPane(_ value: String) {
    guard let id = UUID(uuidString: value) else { return }
    showingExecution = false
    showingHistory = false
    appState.store?.send(.agentState(.rowTapped(PaneID(raw: id))))
  }
}

enum WorkflowRunPresentationV2 {
  static func status(_ status: String) -> String {
    switch status {
    case "waiting": "Waiting for your decision"
    case "running": "Running"
    case "succeeded": "Completed"
    case "failed": "Failed"
    case "cancelled": "Cancelled"
    case "interrupted": "Interrupted"
    default: status.capitalized
    }
  }
}
