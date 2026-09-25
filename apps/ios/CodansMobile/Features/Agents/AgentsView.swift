import CodansIPC
import ComposableArchitecture
import SwiftUI

/// Every agent on the Mac, grouped by needs input / working / idle, shown
/// as a sheet from the workspace toolbar. Picking one hands its pane back
/// to the workspace, which navigates there.
struct AgentsView: View {
  let store: StoreOf<AppFeature>
  let onSelect: (IPC.AgentStateEntry) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      list
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
  }

  @ViewBuilder
  private var list: some View {
    let agents = store.agents
    if !agents.hasSnapshot {
      ContentUnavailableView {
        Label(ConnectionStatusView.title(for: store.connection), systemImage: "sparkles")
      }
    } else if agents.entries.isEmpty {
      ContentUnavailableView(
        "No Agents Running",
        systemImage: "sparkles",
        description: Text("Agents started in Codans on your Mac appear here."))
    } else {
      List {
        ForEach(agents.groups) { group in
          Section(group.kind.title) {
            ForEach(group.entries, id: \.paneID) { entry in
              Button {
                onSelect(entry)
              } label: {
                AgentRow(entry: entry, kind: group.kind)
              }
              .foregroundStyle(.primary)
            }
          }
        }
      }
    }
  }
}

private struct AgentRow: View {
  let entry: IPC.AgentStateEntry
  let kind: AgentGroup.Kind

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: kind.symbol)
          .foregroundStyle(kind.tint)
          .accessibilityHidden(true)
        Text(entry.title ?? entry.tabTitle ?? entry.agentName)
          .font(.headline)
          .lineLimit(1)
      }
      Text("\(entry.agentName) · \(entry.projectName) › \(entry.worktreeName)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(kind.title)
  }
}
