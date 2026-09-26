import CodansIPC
import ComposableArchitecture
import SwiftUI

/// Every agent on the Mac, grouped by needs input / working / idle, shown
/// as a sheet from the home toolbar. Picking one hands its pane back to the
/// workspace, which opens its terminal.
struct AgentsView: View {
  let store: StoreOf<AppFeature>
  let onSelect: (IPC.AgentStateEntry) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      list
        .background(Color.surface)
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
              .fontWeight(.semibold)
          }
        }
    }
  }

  @ViewBuilder
  private var list: some View {
    let agents = store.agents
    if !agents.hasSnapshot {
      List {
        ForEach(0..<4, id: \.self) { index in
          SkeletonRow(variant: [0.2, 0.7, 0.45, 0.9][index])
            .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .accessibilityLabel(store.connection.health.title)
    } else if agents.entries.isEmpty {
      StateView(
        symbol: "sparkles",
        title: "No agents running",
        message: "Agents started in Codans on your Mac, or from the composer here, show up here.")
    } else {
      List {
        ForEach(agents.groups) { group in
          Section {
            ForEach(group.entries, id: \.paneID) { entry in
              Button {
                onSelect(entry)
              } label: {
                AgentRow(entry: entry, kind: group.kind)
              }
              .buttonStyle(.plain)
              .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
              .listRowSeparator(.hidden)
            }
          } header: {
            HStack(spacing: 6) {
              Text(group.kind.title)
              Text("\(group.entries.count)")
                .foregroundStyle(Color.inkTertiary)
                .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.inkSecondary)
            .textCase(nil)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .opacity(store.connection.isLive ? 1 : 0.5)
    }
  }
}

private struct AgentRow: View {
  let entry: IPC.AgentStateEntry
  let kind: AgentGroup.Kind

  var body: some View {
    HStack(spacing: Theme.Space.sm) {
      StatusDot(color: kind.color, pulses: kind == .working, size: 8)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.title ?? entry.tabTitle ?? entry.agentName)
          .font(.system(size: 17))
          .foregroundStyle(Color.ink)
          .lineLimit(1)
        Text("\(entry.agentName) · \(entry.projectName) › \(entry.worktreeName)")
          .font(.rowDetail)
          .foregroundStyle(Color.inkSecondary)
          .lineLimit(1)
      }
      Spacer(minLength: Theme.Space.xs)
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.inkTertiary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 10)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityValue(kind.title)
    .accessibilityIdentifier("agent-row")
  }
}
