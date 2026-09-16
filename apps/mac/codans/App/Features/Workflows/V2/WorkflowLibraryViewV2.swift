import AppKit
import CodansCore
import CodansIPC
import SwiftUI

struct WorkflowRoleSelectionV2 {
  var source: String
  var profileID: UUID?
  var paneID: PaneID?
  var worktreeID: WorktreeID?
}

@MainActor
struct WorkflowLibraryViewV2: View {
  let catalog: WorkflowCatalogV2
  let service: WorkflowServiceV2
  let profiles: [AgentProfile]
  let panes: [WorkflowPaneChoice]
  let workspaces: [WorkflowWorkspaceChoice]
  let creationRequest: UUID?
  let onStart:
    (WorkflowDefinitionV2, String, String, [String: JSONValue], [String: WorkflowRoleSelectionV2]) throws -> UUID
  let onOpenPane: (String) -> Void
  @State private var section = "Definitions"
  @State private var definitionID: String?
  @State private var runID: UUID?
  @State private var search = ""
  @State private var showingNew = false
  @State private var newName = ""
  @State private var errorMessage: String?
  @State private var startingEntry: WorkflowCatalogV2.Entry?

  private var entries: [WorkflowCatalogV2.Entry] {
    catalog.entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
  }

  private var isShowingError: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Workflow library section", selection: $section) {
        Text("Definitions").tag("Definitions")
        Text("Runs").tag("Runs")
      }
      .pickerStyle(.segmented).frame(maxWidth: 320).padding(12)
      Divider()
      HSplitView {
        VStack(spacing: 0) {
          if section == "Definitions" {
            TextField("Find definitions", text: $search)
              .textFieldStyle(.roundedBorder)
              .padding(10)
              .accessibilityLabel("Find Workflow Definitions")
            List(entries, selection: $definitionID) { entry in
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.headline)
                Label(
                  entry.error == nil ? (entry.isBuiltin ? "Built-in" : "Personal") : "Invalid definition",
                  systemImage: entry.error == nil ? "doc.text" : "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(entry.error == nil ? Color.secondary : Color.orange)
              }.padding(.vertical, 3).tag(entry.id)
            }
            .accessibilityLabel("Workflow definitions")
          } else {
            List(service.runs, selection: $runID) { run in
              VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.headline)
                Text("\(run.definition.name) · \(run.status)").font(.caption).foregroundStyle(.secondary)
                Text(run.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2)
              }.padding(.vertical, 3).tag(run.id)
            }.accessibilityLabel("Workflow runs")
          }
        }
        .frame(minWidth: 240, idealWidth: 270, maxWidth: 340, maxHeight: .infinity)
        Group {

          if section == "Definitions", let entry = catalog.entries.first(where: { $0.id == definitionID }) {
            WorkflowDefinitionDetailViewV2(
              entry: entry, catalog: catalog, runs: service.runs.filter { $0.definition.id == entry.definition?.id },
              onRun: { startingEntry = entry }, onDuplicate: { duplicate(entry) },
              onSelectRun: {
                runID = $0
                section = "Runs"
              }
            )
            .id(entry.id)
          } else if section == "Runs", let id = runID, let run = service.run(id) {
            WorkflowRunDetailViewV2(run: run, service: service, onOpenPane: onOpenPane)
              .id(run.id)
          } else {
            ContentUnavailableView(
              section == "Definitions" ? "Select a Definition" : "Select a Run",
              systemImage: section == "Definitions" ? "doc.text" : "list.bullet.rectangle",
              description: Text(
                section == "Definitions"
                  ? "Create a reusable workflow or choose a built-in definition to inspect its roles and YAML."
                  : "Runs preserve the inputs, participants, results, and definition used for each execution."))
          }
        }
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
      }
      if !(catalog.issues + service.issues).isEmpty {
        Divider()
        DisclosureGroup("Diagnostics (\(catalog.issues.count + service.issues.count))") {
          ScrollView {
            Text((catalog.issues + service.issues).joined(separator: "\n"))
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 100)
        }.padding(10).foregroundStyle(.orange)
      }
    }
    .frame(minWidth: 800, minHeight: 540)
    .toolbar {
      Button("New Workflow", systemImage: "plus") {
        newName = ""
        showingNew = true
      }
      .accessibilityLabel("New Workflow Definition")
      Button("Import", systemImage: "square.and.arrow.down") { importDefinition() }
        .accessibilityLabel("Import Workflow Definition")
      Button("Refresh", systemImage: "arrow.clockwise") { catalog.reload() }
        .accessibilityLabel("Refresh Workflow Definitions")
    }
    .sheet(isPresented: $showingNew) {
      VStack(alignment: .leading, spacing: 16) {
        Text("New Workflow Definition").font(.title2)
        Text("Create an editable YAML definition. No agents will start.").foregroundStyle(.secondary)
        TextField("Name", text: $newName).accessibilityLabel("New Workflow Name")
        HStack {
          Button("Cancel") { showingNew = false }
          Spacer()
          Button("Create Definition") {
            do {
              let entry = try catalog.create(name: newName)
              definitionID = entry.id
              section = "Definitions"
              showingNew = false
            } catch { errorMessage = error.localizedDescription }
          }.keyboardShortcut(.defaultAction)
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(24).frame(width: 440)
    }
    .sheet(item: $startingEntry) { entry in
      if let definition = entry.definition {
        WorkflowRunFormViewV2(
          definition: definition, source: entry.source, profiles: profiles, panes: panes, workspaces: workspaces,
          onStart: onStart, onCancel: { startingEntry = nil },
          onStarted: { id in
            runID = id
            section = "Runs"
            startingEntry = nil
          })
      }
    }
    .alert("Workflow Error", isPresented: isShowingError) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .onChange(of: creationRequest) { _, value in
      if value != nil {
        section = "Definitions"
        newName = ""
        showingNew = true
      }
    }
    .onAppear {
      catalog.reload()
      if definitionID == nil { definitionID = catalog.entries.first?.id }
      if creationRequest != nil { showingNew = true }
    }
  }

  private func duplicate(_ entry: WorkflowCatalogV2.Entry) {
    do { definitionID = try catalog.duplicate(entry).id } catch { errorMessage = error.localizedDescription }
  }

  private func importDefinition() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a workflow YAML file to import into your personal definitions."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      definitionID = try catalog.importDefinition(from: url).id
      section = "Definitions"
    } catch { errorMessage = error.localizedDescription }
  }
}

enum WorkflowUIFormatV2 {
  static func json(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "Unable to display value" }
    return String(data: data, encoding: .utf8) ?? "Unable to display value"
  }

  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
