import CodansCore
import SwiftUI

@MainActor
struct WorkflowToolbarViewV2: View {
  let appState: AppState
  @State private var startingEntry: WorkflowCatalogV2.Entry?
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
            selectedHistoryID = id
            historyPinned = true
            showingHistory = true
          }
        }
        Divider()
        Button("Refresh Definitions") { appState.workflowCatalogV2.reload() }
      } label: {
        Label("Run Workflow", systemImage: "point.3.connected.trianglepath.dotted")
      }
      .accessibilityLabel("Run Workflow")
      .help("Run a workflow")
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
      .popover(isPresented: $showingHistory, arrowEdge: .trailing) {
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
      selectedHistoryID = id
    }
    .sheet(
      item: $startingEntry,
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
              showingHistory = false
              historyPinned = false
              hoveringButton = false
              hoveringHistory = false
              appState.workflowPresentedRunID = id
              startingEntry = nil
            })
        }
      })
  }

  private var historyPanel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        historyList.frame(width: 220)
        Divider()
        if let run = appState.workflowServiceV2.runs.first(where: { $0.id == selectedHistoryID })
          ?? appState.workflowServiceV2.runs.first
        {
          WorkflowRunDetailViewV2(
            run: run, service: appState.workflowServiceV2, onOpenPane: openPane
          )
          .id(run.id)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Text("No workflow runs yet.").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }.frame(width: 860, height: 560)
      .font(.system(size: 12))
      .controlSize(.small)
      .onExitCommand { showingHistory = false }
      .background(Color(nsColor: .windowBackgroundColor))
  }

  private var historyList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Workflow History").font(.system(size: 12, weight: .semibold))
        Spacer()
        Text("\(appState.workflowServiceV2.runs.count)").foregroundStyle(.tertiary)
      }.padding(14)
      ScrollView {
        LazyVStack(spacing: 3) {
          ForEach(appState.workflowServiceV2.runs) { run in
            let selected = run.id == (selectedHistoryID ?? appState.workflowServiceV2.runs.first?.id)
            Button {
              historyPinned = true
              selectedHistoryID = run.id
            } label: {
              HStack(alignment: .top, spacing: 8) {
                WorkflowStatusViewV2(status: run.status, showLabel: false).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                  Text(run.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                  Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
              }
              .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
              .padding(10)
              .background(
                selected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open workflow run \(run.title)")
            .accessibilityValue(WorkflowRunPresentationV2.status(run.status))
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }.padding(.horizontal, 6).padding(.bottom, 6)
      }.accessibilityLabel("Workflow Run History")
    }
  }

  private func updateHistoryHover() {
    closeTask?.cancel()
    if startingEntry != nil { return }
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

struct WorkflowStatusViewV2: View {
  let status: String
  var showLabel = true

  private var color: Color {
    switch status {
    case "running": .accentColor
    case "succeeded": .green
    case "waiting", "interrupted": .orange
    case "failed": .red
    default: .secondary
    }
  }

  private var symbol: String {
    switch status {
    case "succeeded": "checkmark.circle.fill"
    case "failed": "xmark.circle.fill"
    case "interrupted": "pause.circle.fill"
    case "cancelled": "minus.circle.fill"
    default: "circle.fill"
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      if status == "running" {
        ProgressView().controlSize(.small).scaleEffect(0.75)
          .frame(width: 12, height: 12).accessibilityHidden(true)
      } else {
        Image(systemName: symbol).font(.system(size: 10))
          .frame(width: 12, height: 12).accessibilityHidden(true)
      }
      if showLabel { Text(WorkflowRunPresentationV2.status(status)) }
    }
    .font(.caption)
    .foregroundStyle(color)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(WorkflowRunPresentationV2.status(status))
  }
}
