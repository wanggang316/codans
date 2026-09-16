import CodansCore
import SwiftUI

@MainActor
struct WorkflowToolbarViewV2: ToolbarContent {
  let appState: AppState
  private enum Presentation: Identifiable {
    case start(WorkflowCatalogV2.Entry)
    case history(UUID?)

    var id: String {
      switch self {
      case .start(let entry): "start:\(entry.id)"
      case .history: "history"
      }
    }
  }

  @State private var presentation: Presentation?
  @State private var selectedRunID: UUID?
  @State private var historySection = "Runs"

  private var runnableEntries: [WorkflowCatalogV2.Entry] {
    appState.workflowCatalogV2.entries.filter { $0.definition != nil && $0.error == nil }
  }

  var body: some ToolbarContent {
    ToolbarItem(id: "workflow-run", placement: .primaryAction) {
      Menu {
        if runnableEntries.isEmpty {
          Text("No valid workflow definitions")
        }
        ForEach(runnableEntries) { entry in
          Button(entry.name) {
            presentation = .start(entry)
          }
        }
        Divider()
        Button("Refresh Definitions") { appState.workflowCatalogV2.reload() }
      } label: {
        Label("Run Workflow", systemImage: "point.3.connected.trianglepath.dotted")
      }
      .accessibilityLabel("Run Workflow")
      .help("Choose a workflow and configure its inputs and participants")
      .onAppear { appState.workflowCatalogV2.reload() }
      .sheet(item: $presentation) { item in
        switch item {
        case .start(let entry):
          if let definition = entry.definition {
            WorkflowRunFormViewV2(
              definition: definition, source: entry.source,
              profiles: appState.settingsStore.settings.agents.enabledProfiles,
              panes: appState.workflowAgentPanesV2, workspaces: appState.workflowWorkspaces,
              onStart: {
                try appState.startWorkflowV2(definition: $0, source: $1, title: $2, inputs: $3, selections: $4)
              },
              onCancel: { presentation = nil },
              onStarted: { id in presentation = .history(id) })
          }
        case .history(let initialRunID):
          history.onAppear {
            if let initialRunID { selectedRunID = initialRunID }
            historySection = "Runs"
          }
        }
      }
    }
    ToolbarItem(id: "workflow-history", placement: .primaryAction) {
      Button {
        presentation = .history(selectedRunID)
      } label: {
        Label("Workflow History", systemImage: "clock.arrow.circlepath")
      }
      .accessibilityLabel("Workflow History")
      .help("Inspect workflow runs, results, and decisions")
    }
  }

  private var history: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Workflow History").font(.title2)
        Spacer()
        Picker("Workflow History Version", selection: $historySection) {
          Text("Runs").tag("Runs")
          Text("Legacy Runs").tag("Legacy")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
        Button("Done") { presentation = nil }.keyboardShortcut(.cancelAction)
      }.padding(16)
      Divider()
      if historySection == "Legacy" {
        WorkflowRunsView(store: appState.workflowStore, allowsCreation: false, onOpenPane: openPane)
      } else {
        HSplitView {
          List(appState.workflowServiceV2.runs, selection: $selectedRunID) { run in
            VStack(alignment: .leading, spacing: 4) {
              Text(run.title).font(.headline)
              Text("\(run.definition.name) · \(run.status)")
                .font(.caption).foregroundStyle(.secondary)
              Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
            }.padding(.vertical, 3).tag(run.id)
          }
          .accessibilityLabel("Workflow Run History")
          .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
          Group {
            if let id = selectedRunID, let run = appState.workflowServiceV2.run(id) {
              WorkflowRunDetailViewV2(run: run, service: appState.workflowServiceV2, onOpenPane: openPane)
                .id(id)
            } else {
              ContentUnavailableView(
                appState.workflowServiceV2.runs.isEmpty ? "No Workflow Runs" : "Select a Run",
                systemImage: "clock.arrow.circlepath",
                description: Text("Review steps, results, and decisions without leaving your workspace."))
            }
          }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        if !appState.workflowServiceV2.issues.isEmpty {
          DisclosureGroup("Workflow Diagnostics") {
            ScrollView {
              Text(appState.workflowServiceV2.issues.joined(separator: "\n"))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
          }.foregroundStyle(.orange).padding(12)
        }
      }
    }.frame(width: 900, height: 650)
  }

  private func openPane(_ value: String) {
    guard let id = UUID(uuidString: value) else { return }
    presentation = nil
    appState.store?.send(.agentState(.rowTapped(PaneID(raw: id))))
  }
}
