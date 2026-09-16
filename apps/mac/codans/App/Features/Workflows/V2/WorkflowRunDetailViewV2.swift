import CodansIPC
import SwiftUI

@MainActor
struct WorkflowRunDetailViewV2: View {
  let run: WorkflowRunV2
  let service: WorkflowServiceV2
  let onOpenPane: (String) -> Void
  @State private var section = "Steps"
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(run.title).font(.title2)
          Text("\(run.definition.name) · \(run.status)").foregroundStyle(.secondary)
          Text(run.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
        }
        Spacer()
        if run.status == "running" || run.status == "waiting" {
          Button("Cancel Run", role: .destructive) {
            do { try service.cancel(run.id) } catch { self.error = error.localizedDescription }
          }.accessibilityLabel("Cancel Workflow Run")
        }
      }
      if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
      Picker("Run detail", selection: $section) {
        Text("Steps").tag("Steps")
        Text("Inputs & Results").tag("Results")
        Text("History").tag("History")
        Text("Frozen YAML").tag("Source")
      }.pickerStyle(.segmented)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch section {
          case "Steps":
            ForEach(run.definition.nodeIDs, id: \.self) { id in
              if let definition = run.definition.nodes[id], let node = run.nodes[id] {
                WorkflowNodeDetailViewV2(
                  runID: run.id, nodeID: id, definition: definition, node: node,
                  service: service, onOpenPane: onOpenPane)
              }
            }
          case "Results":
            jsonGroup("Run Inputs", value: .object(run.inputs))
            jsonGroup("Run Outputs", value: .object(run.outputs))
            GroupBox("Participants") {
              VStack(alignment: .leading, spacing: 12) {
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
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
          case "History":
            ForEach(run.events, id: \.id) { event in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text("#\(event.sequence) · \(event.type)").font(.headline)
                  Spacer()
                  Text(event.date, format: .dateTime.hour().minute().second()).font(.caption)
                }
                if let node = event.nodeID { Text(node).font(.caption).foregroundStyle(.secondary) }
                Text(event.message).textSelection(.enabled)
              }
              Divider()
            }
          default:
            Button("Copy Frozen YAML") { WorkflowUIFormatV2.copy(run.source) }
            Text("This exact definition was saved when the run started.").foregroundStyle(.secondary)
            Text(run.source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(run.id.uuidString).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
    }.padding(20)
  }

  private func jsonGroup(_ title: String, value: JSONValue) -> some View {
    GroupBox(title) {
      Text(WorkflowUIFormatV2.json(value)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
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
  @State private var expanded = true
  @State private var decision = ""
  @State private var reason = ""
  @State private var error: String?

  private var options: [String] {
    guard case .array(let values) = node.inputs["options"] else { return [] }
    return values.compactMap {
      if case .string(let value) = $0 { return value }
      return nil
    }
  }

  var body: some View {
    GroupBox {
      DisclosureGroup(isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 12) {
          Text(definition.uses).font(.caption).foregroundStyle(.secondary)
          if let pane = node.paneID {
            Button("Open Agent") { onOpenPane(pane) }.accessibilityLabel("Open Agent for \(nodeID)")
          }
          if let error = error ?? node.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
          if definition.uses == "codans/human.decide@v1", node.status == "waiting" {
            decisionForm
          }
          if !node.inputs.isEmpty {
            DisclosureGroup("Resolved Inputs") { json(.object(node.inputs)) }
          }
          if !node.outputs.isEmpty {
            DisclosureGroup("Result") { json(.object(node.outputs)) }
          }
          if let attempt = node.attemptID {
            Text("Attempt: \(attempt.uuidString)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
      } label: {
        HStack {
          Text(definition.title ?? nodeID).font(.headline)
          Spacer()
          Text(node.status).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var decisionForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .string(let question) = node.inputs["question"] { Text(question).font(.headline) }
      if let evidence = node.inputs["evidence"] {
        DisclosureGroup("Evidence") { json(evidence) }
      }
      Picker("Decision", selection: $decision) {
        Text("Choose a decision").tag("")
        ForEach(options, id: \.self) { Text($0).tag($0) }
      }.accessibilityLabel("Decision for \(nodeID)")
      TextField("Reason (required)", text: $reason, axis: .vertical).lineLimit(2...6)
        .accessibilityLabel("Decision Reason for \(nodeID)")
      Button("Submit Decision") {
        do { try service.decide(id: runID, nodeID: nodeID, decision: decision, reason: reason) } catch {
          self.error = error.localizedDescription
        }
      }.disabled(decision.isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Submit Decision for \(nodeID)")
    }
  }

  private func json(_ value: JSONValue) -> some View {
    Text(WorkflowUIFormatV2.json(value)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
