import CodansIPC
import SwiftUI

@MainActor
struct WorkflowRunDetailViewV2: View {
  let run: WorkflowRunV2
  let service: WorkflowServiceV2
  let onOpenPane: (String) -> Void
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 7) {
          Text(run.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
          HStack(spacing: 8) {
            Text(run.definition.name).foregroundStyle(.secondary)
            WorkflowStatusViewV2(status: run.status)
          }.font(.system(size: 11))
          Text(run.createdAt, format: .dateTime.month().day().hour().minute())
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
        Menu {
          Button("Copy Run ID") { WorkflowUIFormatV2.copy(run.id.uuidString) }
          Button("Copy Frozen YAML") { WorkflowUIFormatV2.copy(run.source) }
          if run.status == "running" || run.status == "waiting" {
            Divider()
            Button("Cancel Run", role: .destructive) {
              do { try service.cancel(run.id) } catch { self.error = error.localizedDescription }
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Run Actions")
      }.padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
          VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Execution")
            ForEach(run.definition.nodeIDs, id: \.self) { id in
              if let definition = run.definition.nodes[id], let node = run.nodes[id] {
                WorkflowNodeDetailViewV2(
                  runID: run.id, nodeID: id, definition: definition, node: node,
                  service: service, onOpenPane: onOpenPane)
              }
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 14) {
            if !run.outputs.isEmpty {
              DisclosureGroup("Results") { WorkflowValuesViewV2(values: run.outputs) }
            }
            if !run.inputs.isEmpty {
              DisclosureGroup("Inputs") { WorkflowValuesViewV2(values: run.inputs) }
            }
            if !run.bindings.isEmpty {
              DisclosureGroup("Participants") {
                VStack(spacing: 10) {
                  ForEach(run.bindings.keys.sorted(), id: \.self) { key in
                    if let binding = run.bindings[key] {
                      HStack {
                        Text(run.definition.roles[key]?.label ?? key)
                        Text(binding.profile?.displayName ?? binding.source).foregroundStyle(.secondary)
                        Spacer()
                        if let pane = binding.paneID {
                          Button("Open Agent") { onOpenPane(pane.raw.uuidString) }
                        }
                      }
                    }
                  }
                }.padding(.top, 8)
              }
            }
            DisclosureGroup("Activity · \(run.events.count)") {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(run.events, id: \.id) { event in
                  HStack(alignment: .top, spacing: 12) {
                    Text(event.date, format: .dateTime.hour().minute().second())
                      .monospacedDigit().foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(event.type).foregroundStyle(.secondary)
                      Text(event.message).textSelection(.enabled)
                    }
                  }.font(.system(size: 11))
                }
              }.padding(.top, 8)
            }
            DisclosureGroup("Workflow YAML") {
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text("Definition saved when this run started.").foregroundStyle(.secondary)
                  Spacer()
                  Button("Copy") { WorkflowUIFormatV2.copy(run.source) }
                }
                Text(run.source).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
              }.padding(.top, 8)
            }
          }.font(.system(size: 11)).tint(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.font(.system(size: 12)).controlSize(.small)
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      .padding(.bottom, 4)
  }
}

@MainActor
private struct WorkflowNodeDetailViewV2: View {
  let runID: UUID
  let nodeID: String
  let definition: WorkflowNodeV2
  let node: WorkflowNodeRunV2
  let service: WorkflowServiceV2
  let onOpenPane: (String) -> Void
  @State private var expanded = false
  @State private var decision = ""
  @State private var reason = ""
  @State private var error: String?

  private var needsDecision: Bool {
    definition.uses == "codans/human.decide@v1" && node.status == "waiting"
  }

  private var options: [String] {
    guard case .array(let values) = node.inputs["options"] else { return [] }
    return values.compactMap {
      if case .string(let value) = $0 { return value }
      return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        WorkflowStatusViewV2(status: node.status, showLabel: false)
        Button {
          expanded.toggle()
        } label: {
          HStack {
            Text(definition.title ?? nodeID).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Text(WorkflowRunPresentationV2.status(node.status))
              .font(.system(size: 10)).foregroundStyle(.secondary)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Details for \(nodeID)")
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        if let pane = node.paneID {
          Button {
            onOpenPane(pane)
          } label: {
            Image(systemName: "terminal")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help("Open Agent").accessibilityLabel("Open Agent for \(nodeID)")
        }
      }.padding(.vertical, 10)
      if let error = error ?? node.error {
        Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
          .padding(.leading, 20).padding(.bottom, 10)
      }
      if needsDecision {
        decisionForm.padding(.leading, 20).padding(.bottom, 12)
      }
      if expanded {
        VStack(alignment: .leading, spacing: 10) {
          Text(definition.uses).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary).textSelection(.enabled)
          if !node.outputs.isEmpty {
            Text("Result").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            WorkflowValuesViewV2(values: node.outputs)
          }
          if !node.inputs.isEmpty {
            Text("Inputs").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            WorkflowValuesViewV2(values: node.inputs)
          }
          if let attempt = node.attemptID {
            Text("Attempt: \(attempt.uuidString)").font(.system(size: 9, design: .monospaced))
              .foregroundStyle(.tertiary).textSelection(.enabled)
          }
        }.padding(.leading, 20).padding(.bottom, 12)
      }
      Divider().opacity(0.5)
    }
  }

  private var decisionForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .string(let question) = node.inputs["question"] {
        Text(question).font(.system(size: 12, weight: .medium))
      }
      if let evidence = node.inputs["evidence"] {
        Text(evidence.v2Text).font(.system(size: 11)).textSelection(.enabled)
      }
      Picker("Decision", selection: $decision) {
        Text("Choose a decision").tag("")
        ForEach(options, id: \.self) { Text($0).tag($0) }
      }.accessibilityLabel("Decision for \(nodeID)")
      TextField("Reason (required)", text: $reason, axis: .vertical).lineLimit(2...6)
        .textFieldStyle(.roundedBorder).accessibilityLabel("Decision Reason for \(nodeID)")
      Button("Submit Decision") {
        do {
          try service.decide(id: runID, nodeID: nodeID, decision: decision, reason: reason)
        } catch { self.error = error.localizedDescription }
      }.disabled(decision.isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Submit Decision for \(nodeID)")
    }
  }
}

private struct WorkflowValuesViewV2: View {
  let values: [String: JSONValue]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(values.keys.sorted(), id: \.self) { key in
        if let value = values[key] {
          VStack(alignment: .leading, spacing: 4) {
            Text(key).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.v2Text).font(.system(size: 11)).textSelection(.enabled)
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
  }
}
