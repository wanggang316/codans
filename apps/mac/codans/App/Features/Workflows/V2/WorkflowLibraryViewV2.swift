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
  let profiles: [AgentProfile]
  let panes: [WorkflowPaneChoice]
  let workspaces: [WorkflowWorkspaceChoice]
  let creationRequest: UUID?
  let onStart:
    (WorkflowDefinitionV2, String, String, [String: JSONValue], [String: WorkflowRoleSelectionV2])
      throws -> UUID
  var onRunStarted: (UUID) -> Void = { _ in }
  var onCreationRequestHandled: () -> Void = {}

  private enum Destination: Hashable {
    case definition(String)
  }

  @State private var path: [Destination] = []
  @State private var handledCreationRequest: UUID?
  @State private var showingNew = false
  @State private var newName = ""
  @State private var errorMessage: String?
  @State private var startingEntry: WorkflowCatalogV2.Entry?

  private var isShowingError: Binding<Bool> {
    Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
  }

  var body: some View {
    NavigationStack(path: $path) {
      Form {
        Section {
          Text("Choose a workflow to review its roles, edit its YAML, or start a run.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        definitionSection("Built-in", entries: catalog.entries.filter(\.isBuiltin))
        definitionSection("Your Workflows", entries: catalog.entries.filter { !$0.isBuiltin })
        Section {
          HStack(spacing: 12) {
            Button("New Workflow…", systemImage: "plus", action: presentNew)
              .accessibilityLabel("New Workflow Definition")
            Button("Import…", systemImage: "square.and.arrow.down", action: importDefinition)
              .accessibilityLabel("Import Workflow Definition")
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { catalog.reload() }
              .accessibilityLabel("Refresh Workflow Definitions")
          }
        }
        if !catalog.issues.isEmpty {
          Section {
            DisclosureGroup("Diagnostics (\(catalog.issues.count))") {
              Text(catalog.issues.joined(separator: "\n"))
                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Workflows")
      .navigationDestination(for: Destination.self, destination: destination)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .sheet(isPresented: $showingNew) { newDefinitionForm }
    .sheet(item: $startingEntry) { entry in
      if let definition = entry.definition {
        WorkflowRunFormViewV2(
          definition: definition, source: entry.source, profiles: profiles, panes: panes,
          workspaces: workspaces,
          onStart: onStart, onCancel: { startingEntry = nil },
          onStarted: { id in
            startingEntry = nil
            onRunStarted(id)
          })
      }
    }
    .alert("Workflow Error", isPresented: isShowingError) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .onChange(of: creationRequest) { _, _ in consumeCreationRequest() }
    .onAppear {
      catalog.reload()
      consumeCreationRequest()
    }
  }

  private func definitionSection(_ title: String, entries: [WorkflowCatalogV2.Entry]) -> some View {
    Section(title) {
      if entries.isEmpty {
        Text(
          title == "Your Workflows"
            ? "Create or import a workflow to add it here." : "No built-in workflows available."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      ForEach(entries) { entry in
        NavigationLink(value: Destination.definition(entry.id)) {
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.name)
            if entry.error != nil {
              Label("Needs attention", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
            } else if let description = entry.definition?.description {
              Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }.padding(.vertical, 2)
        }
      }
    }
  }

  @ViewBuilder private func destination(_ destination: Destination) -> some View {
    switch destination {
    case .definition(let id):
      if let entry = catalog.entries.first(where: { $0.id == id }) {
        WorkflowDefinitionDetailViewV2(
          entry: entry, catalog: catalog,
          onRun: { startingEntry = entry }, onDuplicate: { duplicate(entry) }
        )
        .id(entry.id)
        .navigationTitle(entry.name)
      } else {
        ContentUnavailableView("Definition Unavailable", systemImage: "doc.text")
      }
    }
  }

  private var newDefinitionForm: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Workflow Definition").font(.title2)
      Text("Create an editable YAML definition. No agents will start.").foregroundStyle(.secondary)
      TextField("Name", text: $newName).accessibilityLabel("New Workflow Name")
      HStack {
        Button("Cancel") { showingNew = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Create Definition") {
          do {
            let entry = try catalog.create(name: newName)
            showingNew = false
            path = [.definition(entry.id)]
          } catch { errorMessage = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
          .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 440)
  }

  private func presentNew() {
    newName = ""
    showingNew = true
  }

  private func consumeCreationRequest() {
    guard let creationRequest, creationRequest != handledCreationRequest else { return }
    handledCreationRequest = creationRequest
    path = []
    presentNew()
    onCreationRequestHandled()
  }

  private func duplicate(_ entry: WorkflowCatalogV2.Entry) {
    do { path.append(.definition(try catalog.duplicate(entry).id)) } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func importDefinition() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "Choose a workflow YAML file to import into your personal definitions."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { path = [.definition(try catalog.importDefinition(from: url).id)] } catch {
      errorMessage = error.localizedDescription
    }
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
