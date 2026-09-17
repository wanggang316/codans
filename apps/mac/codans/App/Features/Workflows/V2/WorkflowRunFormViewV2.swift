import CodansCore
import CodansIPC
import SwiftUI

@MainActor
struct WorkflowRunFormViewV2: View {
  let definition: WorkflowDefinitionV2
  let source: String
  let profiles: [AgentProfile]
  let panes: [WorkflowPaneChoice]
  let workspaces: [WorkflowWorkspaceChoice]
  private let configurationError: String?
  let onStart:
    (WorkflowDefinitionV2, String, String, [String: JSONValue], [String: WorkflowRoleSelectionV2]) throws -> UUID
  let onCancel: () -> Void
  let onStarted: (UUID) -> Void
  @State private var title: String
  @State private var values: [String: String]
  @State private var roles: [String: WorkflowRoleSelectionV2]
  @State private var error: String?
  @State private var starting = false

  init(
    definition: WorkflowDefinitionV2, source: String, profiles: [AgentProfile], panes: [WorkflowPaneChoice],
    workspaces: [WorkflowWorkspaceChoice], currentPaneID: PaneID? = nil, currentWorktreeID: WorktreeID? = nil,
    onStart:
      @escaping (WorkflowDefinitionV2, String, String, [String: JSONValue], [String: WorkflowRoleSelectionV2]) throws ->
      UUID,
    onCancel: @escaping () -> Void, onStarted: @escaping (UUID) -> Void
  ) {
    self.definition = definition
    self.source = source
    self.profiles = profiles
    self.panes = panes
    self.workspaces = workspaces
    self.onStart = onStart
    self.onCancel = onCancel
    self.onStarted = onStarted
    _title = State(initialValue: definition.name)
    _values = State(
      initialValue: definition.inputs.mapValues { input in
        guard let value = input.defaultValue else { return "" }
        if case .string(let text) = value { return text }
        return WorkflowUIFormatV2.json(value)
      })
    var initialRoles: [String: WorkflowRoleSelectionV2] = [:]
    var configurationErrors: [String] = []
    for key in definition.roles.keys.sorted() {
      guard let role = definition.roles[key] else { continue }
      do {
        initialRoles[key] = try WorkflowRoleDefaultsV2.selection(
          for: role, profiles: profiles, panes: panes, workspaces: workspaces,
          currentPaneID: currentPaneID, currentWorktreeID: currentWorktreeID)
      } catch {
        initialRoles[key] = WorkflowRoleSelectionV2(source: role.source)
        configurationErrors.append(error.localizedDescription)
      }
    }
    configurationError = configurationErrors.isEmpty ? nil : configurationErrors.joined(separator: "\n")
    _roles = State(initialValue: initialRoles)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Run \(definition.name)").font(.title2).padding(.horizontal, 20).padding(.top, 20)
      Form {
        Section("Run") { TextField("Title", text: $title).accessibilityLabel("Workflow Run Title") }
        if !definition.inputs.isEmpty {
          Section("Inputs") {
            ForEach(definition.inputs.keys.sorted(), id: \.self) { key in
              if let input = definition.inputs[key] { inputField(key, input: input) }
            }
          }
        }
        if !definition.roles.isEmpty {
          ForEach(definition.roles.keys.sorted(), id: \.self) { key in
            if let role = definition.roles[key] {
              Section(role.label) { roleFields(key, role: role) }
            }
          }
        }
      }.formStyle(.grouped)
      if let message = configurationError ?? error {
        Text(message).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 20)
      }
      HStack {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Spacer()
        Button("Start Run", action: start).keyboardShortcut(.defaultAction).disabled(
          starting || configurationError != nil
        )
        .accessibilityLabel("Start Workflow Run")
      }.padding(20)
    }.frame(width: 640, height: 660)
  }

  @ViewBuilder private func inputField(_ key: String, input: WorkflowInputV2) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("\(key)\(input.required == true ? " *" : "")").font(.headline)
      if let description = input.description { Text(description).font(.caption).foregroundStyle(.secondary) }
      if input.type == "boolean" {
        Picker(key, selection: valueBinding(key)) {
          Text("Not specified").tag("")
          Text("True").tag("true")
          Text("False").tag("false")
        }.labelsHidden().accessibilityLabel("Input \(key)")
      } else if input.type == "string" || input.type == "object" || input.type == "array" {
        TextEditor(text: valueBinding(key)).frame(minHeight: 70, maxHeight: 130)
          .font(input.type == "string" ? .body : .system(.body, design: .monospaced))
          .accessibilityLabel("Input \(key)")
      } else {
        TextField(input.type, text: valueBinding(key)).accessibilityLabel("Input \(key)")
      }
      if input.type == "object" || input.type == "array" {
        Text("Enter valid JSON.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func roleFields(_ key: String, role: WorkflowRoleV2) -> some View {
    if let description = role.description { Text(description).foregroundStyle(.secondary) }
    if role.source == "launch" {
      if let reference = role.profile {
        LabeledContent("Agent Profile") {
          Text(profiles.first(where: { $0.id == roles[key]?.profileID })?.displayName ?? reference)
            .foregroundStyle(.secondary)
        }.accessibilityLabel("\(role.label) Agent Profile")
      } else {
        Picker("Agent Profile", selection: roleBinding(key, \.profileID)) {
          Text("Choose a profile").tag(UUID?.none)
          ForEach(profiles.filter(\.isEnabled)) { profile in
            Text(profile.displayName).tag(Optional(profile.id))
          }
        }.accessibilityLabel("\(role.label) Agent Profile")
      }
      Picker("Terminal Location", selection: roleBinding(key, \.worktreeID)) {
        Text("Choose a terminal location").tag(WorktreeID?.none)
        ForEach(workspaces) { workspace in Text(workspace.title).tag(Optional(workspace.id)) }
      }.accessibilityLabel("\(role.label) Terminal Location")
      Text("A new agent terminal will open at this location.").font(.caption).foregroundStyle(.secondary)
    } else {
      Picker(role.source == "current" ? "Current Agent" : "Existing Agent", selection: roleBinding(key, \.paneID)) {
        Text("Choose an existing agent").tag(PaneID?.none)
        ForEach(panes) { pane in Text(pane.title).tag(Optional(pane.id)) }
      }.accessibilityLabel("\(role.label) Existing Agent")
    }
  }

  private func valueBinding(_ key: String) -> Binding<String> {
    Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
  }

  private func roleBinding<Value>(_ key: String, _ path: WritableKeyPath<WorkflowRoleSelectionV2, Value>) -> Binding<
    Value
  > {
    Binding(get: { roles[key]![keyPath: path] }, set: { roles[key]?[keyPath: path] = $0 })
  }

  private func start() {
    guard !starting else { return }
    starting = true
    defer { starting = false }
    do {
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Enter a run title.") }
      var inputs: [String: JSONValue] = [:]
      for (key, input) in definition.inputs {
        let raw = values[key] ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          if input.required == true { throw invalid("Input \(key) is required.") }
          continue
        }
        if input.type == "string" {
          inputs[key] = .string(raw)
          continue
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
          throw invalid("Input \(key) must be valid \(input.type) JSON.")
        }
        let valid: Bool
        switch (input.type, value) {
        case ("integer", .int), ("number", .int), ("number", .double), ("boolean", .bool), ("object", .object),
          ("array", .array):
          valid = true
        default: valid = false
        }
        guard valid else { throw invalid("Input \(key) must be \(input.type).") }
        inputs[key] = value
      }
      for (key, selection) in roles {
        if selection.source == "launch" {
          guard selection.profileID != nil, selection.worktreeID != nil else {
            throw invalid("Choose an agent profile and terminal location for \(definition.roles[key]?.label ?? key).")
          }
        } else if selection.paneID == nil {
          throw invalid("Choose an existing agent for \(definition.roles[key]?.label ?? key).")
        }
      }
      onStarted(try onStart(definition, source, title, inputs, roles))
    } catch { self.error = error.localizedDescription }
  }

  private func invalid(_ message: String) -> WorkflowDefinitionErrorV2 { WorkflowDefinitionErrorV2(message: message) }
}
