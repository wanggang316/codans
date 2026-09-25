import CodansCore
import ComposableArchitecture
import SwiftUI

/// Native toolbar split button that starts a coding agent in the selected
/// Worktree. Sits immediately left of the Run split button: both halves of
/// the toolbar's action cluster are "start something here", with agents first
/// because that is the more frequent entry point for this app's audience.
///
/// Primary action launches the first offered `AgentProfile`; the chevron half
/// lists every offered profile plus a "Manage Agents…" footer. "Offered" is
/// the enabled profiles minus those whose CLI the shell could not resolve —
/// see `AgentInstallationStore.offeredProfiles` for why that filter fails
/// open. Empty-state:
/// both halves route to the Agents settings pane so a user with no configured
/// profile lands where they can make one.
///
/// Hand off is deliberately absent: it acts on the agent in one pane, and the
/// pane's own info menu resolves that source directly instead of going
/// through the header's focused-pane guess.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.launchAgentProfile` effect and
/// resolves the target Worktree at handle-time.
struct HeaderAgentSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  /// The selected local worktree; `nil` for a remote one, which has no
  /// workflow catalog to offer.
  var worktreePath: String?
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(WorkflowCatalogStore.self) private var workflowCatalog
  @Environment(AgentInstallationStore.self) private var installation

  var body: some View {
    // Read the profiles once, here, inside body — Observation only tracks
    // reads that happen during a body re-evaluation, and the array doubles as
    // the Menu's `.id(_:)` identity so a Settings-side edit rebuilds the
    // cached NSMenu instead of serving stale items. Same rationale as
    // `HeaderRunScriptSplitButton`.
    let profiles = AgentInstallationStore.offeredProfiles(
      enabled: settingsStore.settings.agents.enabledProfiles,
      isInstalled: installation.isInstalled
    )
    let primary = profiles.first
    let primaryName = primary?.displayName ?? "Agents"

    Menu {
      caretMenu(profiles: profiles)
    } label: {
      // Glyph only, no `Label(_:systemImage:)`, for the same reason as the
      // Run button: the toolbar's default LabelStyle collapses a Label in
      // ways that fight a custom leading glyph. The agent's name lives in
      // the tooltip and accessibility label so the three header capsules
      // stay the same compact icon + chevron shape.
      if let primary {
        AgentLogoView(icon: primary.icon, size: 16, tint: .primary)
      } else {
        Image(systemName: "sparkles")
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
      }
    } primaryAction: {
      if let primary {
        store.send(.launchAgentTapped(profileID: primary.id))
      } else {
        store.send(.manageAgentsTapped)
      }
    }
    .menuIndicator(.visible)
    .accessibilityLabel(primary == nil ? "Manage agents" : "Start \(primaryName)")
    .help(primary == nil ? "Manage Agents…" : "Start \(primaryName)")
    .id(Self.identitySignature(of: profiles) + workflowSignature)
  }

  // MARK: - Caret menu

  @ViewBuilder
  private func caretMenu(profiles: [AgentProfile]) -> some View {
    if !profiles.isEmpty {
      ForEach(profiles) { profile in
        Button {
          store.send(.launchAgentTapped(profileID: profile.id))
        } label: {
          Label {
            Text(profile.displayName)
          } icon: {
            // The Label's Text already announces the profile; letting
            // VoiceOver read the glyph too would double-speak it.
            AgentMenuIcon.image(for: profile.icon)
              .accessibilityHidden(true)
          }
        }
      }
      Divider()
    }
    if workflowsEnabled {
      Menu {
        workflowMenu
      } label: {
        Label("Run Workflow", systemImage: "arrow.triangle.branch")
      }
      Divider()
    }
    Button("Manage Agents…") {
      store.send(.manageAgentsTapped)
    }
  }

  private var workflowsEnabled: Bool { settingsStore.settings.workflows.isEnabled }

  /// The workflows a run here would resolve against, minus the ones the user
  /// switched off. Invalid files stay listed but disabled, so a workflow
  /// that "went missing" after an edit explains itself instead of vanishing.
  private var workflowRows: [WorkflowCatalogEntry] {
    let settings = settingsStore.settings.workflows
    return workflowCatalog.catalog(forWorktreePath: worktreePath)
      .filter { !settings.isDisabled($0.id) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  @ViewBuilder
  private var workflowMenu: some View {
    let rows = workflowRows
    if worktreePath == nil {
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

  /// Folds the workflow rows into the menu identity: the cached NSMenu is
  /// rebuilt when a watched file appears, changes validity, or is renamed.
  private var workflowSignature: String {
    guard workflowsEnabled else { return "" }
    return "|workflows:" + workflowRows.map { "\($0.id)=\($0.name)=\($0.isValid)" }.joined(separator: ",")
  }

  /// Stable identity for `.id(_:)`. Folds every field the menu renders plus
  /// the list's order, so a rename / reorder / enable-toggle in Settings
  /// invalidates the cached NSMenu.
  private static func identitySignature(of profiles: [AgentProfile]) -> String {
    profiles
      .map { "\($0.id)|\($0.displayName)|\($0.kind.rawValue)|\($0.systemImage ?? "")" }
      .joined(separator: "·")
  }
}
