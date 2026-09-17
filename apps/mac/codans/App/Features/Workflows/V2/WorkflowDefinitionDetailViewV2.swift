import AppKit
import SwiftUI

@MainActor
struct WorkflowDefinitionDetailViewV2: View {
  let entry: WorkflowCatalogV2.Entry
  let catalog: WorkflowCatalogV2
  let onDuplicate: () -> Void
  @State private var section = "Overview"
  @State private var source: String
  @State private var error: String?
  @State private var hasExternalConflict = false

  init(
    entry: WorkflowCatalogV2.Entry, catalog: WorkflowCatalogV2,
    onDuplicate: @escaping () -> Void
  ) {
    self.entry = entry
    self.catalog = catalog
    self.onDuplicate = onDuplicate
    _source = State(initialValue: entry.source)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Picker("Definition detail", selection: $section) {
          Text("Overview").tag("Overview")
          Text("YAML").tag("Source")
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
        Spacer(minLength: 8)
        Text(entry.isBuiltin ? "Built-in" : "Personal")
          .font(.system(size: 11)).foregroundStyle(.secondary)
        definitionMenu
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      Divider()
      if let message = error ?? entry.error {
        Text(message).foregroundStyle(.orange).textSelection(.enabled)
          .padding(16)
      }
      if section == "Source" || entry.definition == nil {
        sourceEditor
      } else {
        overview
      }
    }
    .font(.system(size: 12))
    .controlSize(.small)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: entry.source) { previous, current in
      if source == previous || source == current {
        source = current
        hasExternalConflict = false
      } else {
        hasExternalConflict = true
      }
    }
  }

  private var definitionMenu: some View {
    Menu {
      Button("Reveal in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
      }
      .accessibilityLabel("Reveal Workflow YAML in Finder")
      Button("Open in Editor", systemImage: "square.and.pencil") {
        NSWorkspace.shared.open(entry.url)
      }
      Button("Copy YAML", systemImage: "doc.on.doc") { WorkflowUIFormatV2.copy(source) }
      Divider()
      Button("Create Editable Copy", systemImage: "plus.square.on.square", action: onDuplicate)
    } label: {
      Image(systemName: "ellipsis").frame(width: 20, height: 20)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Definition actions")
    .accessibilityLabel("Workflow Definition Actions")
  }

  private var sourceEditor: some View {
    VStack(alignment: .leading, spacing: 0) {
      if hasExternalConflict {
        Text(
          "The file changed outside this editor. Your edits are preserved. Copy them if needed, then discard changes to load the current file before saving."
        )
        .foregroundStyle(.orange).padding(16)
        .accessibilityLabel("Workflow YAML External Edit Conflict")
      }
      if entry.isBuiltin {
        ScrollView([.horizontal, .vertical]) {
          Text(source)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Built-in Workflow YAML")
      } else {
        TextEditor(text: $source)
          .font(.system(size: 11, design: .monospaced))
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .textBackgroundColor))
          .accessibilityLabel("Workflow YAML Editor")
      }
      Divider()
      HStack(spacing: 10) {
        Text(entry.isBuiltin ? "Read-only definition" : source == entry.source ? "Saved" : "Unsaved changes")
          .foregroundStyle(.secondary)
        Spacer()
        if !entry.isBuiltin {
          Button("Discard Changes") {
            source = entry.source
            error = nil
            hasExternalConflict = false
          }
          .disabled(source == entry.source && !hasExternalConflict)
          Button("Save") {
            do {
              try catalog.save(entry, source: source)
              error = nil
            } catch { self.error = error.localizedDescription }
          }
          .buttonStyle(.borderedProminent)
          .disabled(source == entry.source || hasExternalConflict)
          .accessibilityLabel("Save Workflow Definition")
        }
      }
      .font(.system(size: 11))
      .padding(.horizontal, 16).padding(.vertical, 10)
    }
    .frame(maxHeight: .infinity)
  }

  private var overview: some View {
    ScrollView {
      if let definition = entry.definition {
        VStack(alignment: .leading, spacing: 20) {
          if let description = definition.description, !description.isEmpty {
            Text(description).foregroundStyle(.secondary).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          overviewSection("Inputs", count: definition.inputs.count) {
            if definition.inputs.isEmpty {
              Text("No inputs required").foregroundStyle(.secondary)
            }
            ForEach(definition.inputs.keys.sorted(), id: \.self) { key in
              if let input = definition.inputs[key] {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(key).textSelection(.enabled)
                  Spacer(minLength: 8)
                  Text(input.type).foregroundStyle(.secondary)
                  if input.required == true {
                    Text("Required").font(.system(size: 10)).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
          overviewSection("Roles", count: definition.roles.count) {
            if definition.roles.isEmpty {
              Text("No agents required").foregroundStyle(.secondary)
            }
            ForEach(definition.roles.keys.sorted(), id: \.self) { key in
              if let role = definition.roles[key] {
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(role.label).fontWeight(.medium)
                    Spacer()
                    Text(role.source.capitalized).foregroundStyle(.secondary)
                  }
                  if let description = role.description {
                    Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }
            }
          }
          overviewSection("Steps", count: definition.nodeIDs.count) {
            ForEach(Array(definition.nodeIDs.enumerated()), id: \.element) { index, id in
              if let node = definition.nodes[id] {
                HStack(alignment: .top, spacing: 10) {
                  Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(node.title ?? id).fontWeight(.medium)
                    Text(node.uses).font(.system(size: 10, design: .monospaced))
                      .foregroundStyle(.secondary).textSelection(.enabled)
                    if let role = node.role {
                      Text("Role: \(definition.roles[role]?.label ?? role)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let needs = node.needs, !needs.isEmpty {
                      Text("After: \(needs.joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }
          }
          HStack(spacing: 8) {
            Text("Definition ID").foregroundStyle(.secondary)
            Text(definition.id).textSelection(.enabled)
          }
          .font(.system(size: 10))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func overviewSection<Content: View>(
    _ title: String, count: Int, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Text(title).fontWeight(.semibold)
        Text("\(count)").foregroundStyle(.tertiary)
      }
      Divider()
      VStack(alignment: .leading, spacing: 12, content: content)
    }
  }
}
