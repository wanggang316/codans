import AppKit
import SwiftUI

@MainActor
struct WorkflowDefinitionDetailViewV2: View {
  let entry: WorkflowCatalogV2.Entry
  let catalog: WorkflowCatalogV2
  let onRun: () -> Void
  let onDuplicate: () -> Void
  @State private var section = "Overview"
  @State private var source: String
  @State private var error: String?
  @State private var hasExternalConflict = false

  init(
    entry: WorkflowCatalogV2.Entry, catalog: WorkflowCatalogV2,
    onRun: @escaping () -> Void,
    onDuplicate: @escaping () -> Void
  ) {
    self.entry = entry
    self.catalog = catalog
    self.onRun = onRun
    self.onDuplicate = onDuplicate
    _source = State(initialValue: entry.source)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.name).font(.title2)
          Text(entry.isBuiltin ? "Built-in · duplicate to edit" : "Personal definition")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Duplicate", action: onDuplicate)
        Button("Run…", action: onRun)
          .disabled(entry.definition == nil || source != entry.source || hasExternalConflict)
          .accessibilityLabel("Run Selected Workflow")
      }
      if let message = error ?? entry.error {
        Text(message).foregroundStyle(.orange).textSelection(.enabled)
      }
      Picker("Definition detail", selection: $section) {
        Text("Overview").tag("Overview")
        Text("YAML Source").tag("Source")
      }.pickerStyle(.segmented).labelsHidden()
      if section == "Source" || entry.definition == nil {
        sourceEditor
      } else {
        overview
      }
    }.padding(20)
      .onChange(of: entry.source) { previous, current in
        if source == previous || source == current {
          source = current
          hasExternalConflict = false
        } else {
          hasExternalConflict = true
        }
      }
  }

  private var sourceEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(entry.url.path)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityLabel("Workflow YAML File Path")
      Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        .accessibilityLabel("Reveal Workflow YAML in Finder")
      if hasExternalConflict {
        Text(
          "The file changed outside this editor. Your edits are preserved. Copy them if needed, then discard changes to load the current file before saving."
        )
        .font(.callout)
        .foregroundStyle(.orange)
        .accessibilityLabel("Workflow YAML External Edit Conflict")
      }
      HStack {
        Button("Copy YAML") { WorkflowUIFormatV2.copy(source) }
        Button("Open in Editor") { NSWorkspace.shared.open(entry.url) }
        Spacer()
        if !entry.isBuiltin {
          Button("Discard Changes") {
            source = entry.source
            error = nil
            hasExternalConflict = false
          }.disabled(source == entry.source && !hasExternalConflict)
          Button("Save Definition") {
            do {
              try catalog.save(entry, source: source)
              error = nil
            } catch { self.error = error.localizedDescription }
          }.disabled(source == entry.source || hasExternalConflict).accessibilityLabel(
            "Save Workflow Definition")
        }
      }
      if entry.isBuiltin {
        ScrollView([.horizontal, .vertical]) {
          Text(source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
        }.accessibilityLabel("Built-in Workflow YAML")
      } else {
        TextEditor(text: $source).font(.system(.body, design: .monospaced))
          .accessibilityLabel("Workflow YAML Editor")
      }
      if source != entry.source {
        Text("Unsaved changes. Save before starting a run.").font(.caption).foregroundStyle(
          .secondary)
      }
    }.frame(maxHeight: .infinity)
  }

  private var overview: some View {
    Form {
      if let definition = entry.definition {
        Section {
          Text(definition.description ?? "Reusable workflow definition").textSelection(.enabled)
          LabeledContent("Definition ID", value: definition.id)
        }
        Section("Inputs") {
          if definition.inputs.isEmpty { Text("No inputs").foregroundStyle(.secondary) }
          ForEach(definition.inputs.keys.sorted(), id: \.self) { key in
            if let input = definition.inputs[key] {
              Text("\(key) · \(input.type)\(input.required == true ? " · required" : "")")
            }
          }
        }
        Section("Roles") {
          if definition.roles.isEmpty { Text("No agents required").foregroundStyle(.secondary) }
          ForEach(definition.roles.keys.sorted(), id: \.self) { key in
            if let role = definition.roles[key] {
              VStack(alignment: .leading, spacing: 3) {
                Text("\(role.label) · \(role.source)").font(.headline)
                if let description = role.description {
                  Text(description).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        Section("Steps") {
          ForEach(definition.nodeIDs, id: \.self) { id in
            if let node = definition.nodes[id] {
              VStack(alignment: .leading, spacing: 3) {
                Text(node.title ?? id).font(.headline)
                Text(node.uses).font(.caption).foregroundStyle(.secondary)
                if let role = node.role { Text("Role: \(role)").font(.caption) }
                if let needs = node.needs, !needs.isEmpty {
                  Text("After: \(needs.joined(separator: ", "))").font(.caption)
                }
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}
