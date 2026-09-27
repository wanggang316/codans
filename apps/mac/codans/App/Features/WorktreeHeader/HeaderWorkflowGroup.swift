import CodansCore
import ComposableArchitecture
import SwiftUI

/// The toolbar's workflow capsule, beside the Agents / Run / Open chips:
/// a menu that starts a workflow in the selected worktree, and a button
/// that opens the Workflow Runs window. The second one carries the runs'
/// state — a small spinner while any run is going, an orange dot while one
/// is waiting on the user — so a run in the background is never invisible.
///
/// Menu picks dispatch through `WorktreeHeaderFeature.delegate`, so
/// `RootFeature` resolves the target worktree at handle-time exactly as it
/// does for agents and scripts.
struct HeaderWorkflowGroup: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  /// The selected local worktree; `nil` for a remote one, which has no
  /// workflow catalog to offer.
  var worktreePath: String?

  @Environment(SettingsStore.self) private var settingsStore
  @Environment(WorkflowCatalogStore.self) private var workflowCatalog
  @Environment(WorkflowRunsNavigator.self) private var navigator
  @Environment(\.workflowEngine) private var engine
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    HStack(spacing: 2) {
      Menu {
        workflowMenu
      } label: {
        Image(systemName: "arrow.triangle.branch")
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
      }
      .menuIndicator(.visible)
      .fixedSize()
      .help("Run a workflow in this worktree")
      .accessibilityLabel("Run Workflow")
      .accessibilityIdentifier("toolbar.workflow.menu")
      .id(menuSignature)

      Button {
        navigator.show(worktreePath: worktreePath)
        openWindow(id: CodansApp.workflowRunsWindowID)
      } label: {
        runsGlyph
      }
      .help(runsHelp)
      .accessibilityLabel("Workflow Runs")
      .accessibilityIdentifier("toolbar.workflow.runs")
    }
  }

  // MARK: - Runs button

  private var activeRuns: [WorkflowRunSession] { engine?.activeRuns ?? [] }
  private var needsAttention: Bool { activeRuns.contains { $0.attention != nil } }

  private var runsGlyph: some View {
    Image(systemName: "clock.arrow.circlepath")
      .frame(width: 16, height: 16)
      .overlay(alignment: .topTrailing) {
        if needsAttention {
          Circle()
            .fill(.orange)
            .frame(width: 7, height: 7)
            .offset(x: 3, y: -2)
        } else if !activeRuns.isEmpty {
          Circle()
            .fill(.tint)
            .frame(width: 6, height: 6)
            .offset(x: 3, y: -2)
        }
      }
      .accessibilityHidden(true)
  }

  private var runsHelp: String {
    if needsAttention { return "Workflow Runs — a run needs your attention" }
    switch activeRuns.count {
    case 0: return "Workflow Runs"
    case 1: return "Workflow Runs — 1 running"
    default: return "Workflow Runs — \(activeRuns.count) running"
    }
  }

  // MARK: - Workflow menu

  /// The workflows a run here would resolve against, minus the ones the user
  /// switched off. Invalid files stay listed but disabled, so a workflow
  /// that "went missing" after an edit explains itself instead of vanishing.
  private var workflowRows: [WorkflowCatalogEntry] {
    let settings = settingsStore.settings.workflows
    guard settings.isEnabled else { return [] }
    return workflowCatalog.catalog(forWorktreePath: worktreePath)
      .filter { !settings.isDisabled($0.id) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  @ViewBuilder
  private var workflowMenu: some View {
    let rows = workflowRows
    if !settingsStore.settings.workflows.isEnabled {
      Text("Agent Workflows are turned off")
    } else if worktreePath == nil {
      Text("Workflows run in local worktrees only")
    } else if rows.isEmpty {
      Text("No workflows yet")
    } else {
      ForEach(rows, id: \.id) { entry in
        Button {
          store.send(.runWorkflowTapped(workflowID: entry.id))
        } label: {
          Text(entry.isValid ? entry.name : "\(entry.name) — has errors")
        }
        .disabled(!entry.isValid)
        .help(entry.definition?.description ?? "Fix the file's errors in Settings → Workflows.")
      }
    }
    Divider()
    Button("New Workflow…") { store.send(.newWorkflowTapped) }
    Button("Manage Workflows…") { store.send(.manageWorkflowsTapped) }
  }

  /// Rebuilds the cached NSMenu when a watched file appears, changes
  /// validity or is renamed, or workflows are switched on or off.
  private var menuSignature: String {
    "\(settingsStore.settings.workflows.isEnabled)|\(worktreePath ?? "")|"
      + workflowRows.map { "\($0.id)=\($0.name)=\($0.isValid)" }.joined(separator: ",")
  }
}
