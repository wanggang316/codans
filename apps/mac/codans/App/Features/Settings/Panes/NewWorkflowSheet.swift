import CodansCore
import SwiftUI

/// Settings → Workflows → "New Workflow…": name the workflow, pick where the
/// file lives (the user scope or a repository), and start from a blank
/// starter or a copy of any valid definition. Writing goes through
/// `WorkflowScaffold`, which never overwrites; the caller refreshes the
/// list and opens the file.
struct NewWorkflowSheet: View {
  struct Location: Identifiable {
    let id: String
    let title: String
    let directory: URL
    /// Set for a repository location — its `.codans/.gitignore` must let
    /// `workflows/` through so the new file can be committed.
    let worktreeRoot: URL?
    let projectID: ProjectID?
  }

  struct Starter: Identifiable {
    let id: String
    let title: String
    let source: WorkflowScaffold.Source
  }

  let locations: [Location]
  let starters: [Starter]
  let onCreated: (URL, Location) -> Void
  let onCancel: () -> Void

  @State private var name = ""
  @State private var id = ""
  /// Once the user types an id of their own, the name stops rewriting it.
  @State private var idEdited = false
  @State private var locationID: String
  @State private var starterID: String
  @State private var failure: String?
  @FocusState private var nameFocused: Bool

  init(
    locations: [Location],
    starters: [Starter],
    onCreated: @escaping (URL, Location) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.locations = locations
    self.starters = starters
    self.onCreated = onCreated
    self.onCancel = onCancel
    _locationID = State(initialValue: locations.first?.id ?? "")
    _starterID = State(initialValue: starters.first?.id ?? "")
  }

  private var location: Location? { locations.first { $0.id == locationID } }
  private var starter: Starter? { starters.first { $0.id == starterID } }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

  /// Why Create is unavailable, checked against the disk so an id that is
  /// already taken is refused before the write.
  private var problem: String? {
    if trimmedName.isEmpty { return "Give the workflow a name." }
    if id.isEmpty { return "Give the workflow an id — it becomes the file name." }
    if !WorkflowDefinition.isValidIdentifier(id) { return WorkflowScaffold.Failure.invalidID(id).message }
    if let location,
      FileManager.default.fileExists(
        atPath: WorkflowScaffold.fileURL(id: id, in: location.directory).path(percentEncoded: false))
    {
      return "\"\(id)\" already exists in \(location.title)."
    }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("New Workflow")
        .font(.headline)
      Form {
        TextField("Name", text: $name, prompt: Text("Second Opinion"))
          .focused($nameFocused)
          .onChange(of: name) { _, newValue in
            guard !idEdited else { return }
            id = WorkflowScaffold.suggestedID(forName: newValue) ?? ""
          }
        TextField(
          "ID",
          text: Binding(
            get: { id },
            set: {
              id = $0
              idEdited = true
            }),
          prompt: Text("second-opinion"))
        Picker("Location", selection: $locationID) {
          ForEach(locations) { location in
            Text(location.title).tag(location.id)
          }
        }
        Picker("Start from", selection: $starterID) {
          ForEach(starters) { starter in
            Text(starter.title).tag(starter.id)
          }
        }
        if let location {
          LabeledContent("File") {
            Text(filePath(in: location))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
              .textSelection(.enabled)
          }
        }
      }
      .formStyle(.columns)
      if let message = failure ?? problem, !(failure == nil && trimmedName.isEmpty) {
        Text(message)
          .font(.caption)
          .foregroundStyle(failure == nil ? .secondary : Color.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Create", action: create)
          .keyboardShortcut(.defaultAction)
          .disabled(problem != nil)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { nameFocused = true }
    .onChange(of: id) { failure = nil }
    .onChange(of: locationID) { failure = nil }
  }

  private func filePath(in location: Location) -> String {
    let path = WorkflowScaffold.fileURL(id: id.isEmpty ? "<id>" : id, in: location.directory)
      .path(percentEncoded: false)
    return (path as NSString).abbreviatingWithTildeInPath
  }

  private func create() {
    guard problem == nil, let location, let starter else { return }
    do {
      if let root = location.worktreeRoot {
        try WorkflowRunStore.ensureIgnoreFile(worktreeRoot: root)
      }
      let url = try WorkflowScaffold.create(
        id: id, name: trimmedName, source: starter.source, in: location.directory)
      onCreated(url, location)
    } catch let error as WorkflowScaffold.Failure {
      failure = error.message
    } catch {
      failure = error.localizedDescription
    }
  }
}
