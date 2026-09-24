import CodansIPC
import ComposableArchitecture
import SwiftUI

/// Agents grouped by needs input / working / idle; selecting one shows its
/// pane. A two-column split view collapses into a stack in compact width,
/// so the same code serves iPhone, iPad and both iPhone Duo displays.
struct AgentsView: View {
  let store: StoreOf<AppFeature>
  let openSettings: () -> Void

  @SceneStorage("agents.selectedPane") private var selectedPaneID: String?

  var body: some View {
    NavigationSplitView {
      list
        .navigationTitle("Agents")
    } detail: {
      if let paneID = selectedPaneID {
        PaneDetailContainer(store: store, paneID: paneID)
      } else {
        ContentUnavailableView("Select an Agent", systemImage: "sparkles")
      }
    }
  }

  @ViewBuilder
  private var list: some View {
    let agents = store.agents
    if !agents.hasSnapshot {
      ConnectionPlaceholderView(connection: store.connection, openSettings: openSettings)
    } else if agents.entries.isEmpty {
      ContentUnavailableView(
        "No Agents Running",
        systemImage: "sparkles",
        description: Text("Agents started in Codans on your Mac appear here."))
    } else {
      List(selection: $selectedPaneID) {
        ForEach(agents.groups) { group in
          Section(group.kind.title) {
            ForEach(group.entries, id: \.paneID) { entry in
              AgentRow(entry: entry, kind: group.kind)
                .tag(entry.paneID)
            }
          }
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        ConnectionBanner(connection: store.connection)
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
        Image(systemName: symbol)
          .foregroundStyle(tint)
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

  private var symbol: String {
    switch kind {
    case .needsInput: return "exclamationmark.bubble.fill"
    case .working: return "circle.dotted.circle"
    case .idle: return "moon.zzz"
    }
  }

  private var tint: Color {
    switch kind {
    case .needsInput: return .orange
    case .working: return .blue
    case .idle: return .secondary
    }
  }
}
