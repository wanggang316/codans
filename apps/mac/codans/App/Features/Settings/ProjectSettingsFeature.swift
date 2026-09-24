import ComposableArchitecture
import Foundation
import SwiftUI
import CodansCore

@Reducer
struct ProjectSettingsFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let projectID: ProjectID
    /// Derived from `Project.gitRoot` at pane-materialise time. Views consult this to
    /// gate git-specific controls; the sidebar uses it to decide which sub-rows render.
    /// Seeded from `HierarchyClient.kind(of:)` by `SettingsWindowFeature.ensureProjectPane`;
    /// re-seeded when `.projectsChanged` delta reveals a kind flip on an existing pane.
    var kind: ProjectKind = .gitRepo
    var lastWriteFailure: String?
    /// Worktree the Scripts pane targets when the user clicks Run. The
    /// parent feature (`SettingsWindowFeature`) populates this from the
    /// most-recently focused worktree of the selected Project; when nil
    /// the pane falls back to the catalog's first worktree, and disables
    /// Run when neither resolves.
    var lastFocusedWorktreeID: WorktreeID?
    /// Commands detected in the Project's manifests, offered by the Commands
    /// pane's `+` menu. Derived on every scan, never persisted.
    var commandSuggestions: [CommandSuggestionGroup] = []
    var isScanningCommandSuggestions = false

    var id: ProjectID { projectID }
  }

  enum Action: Equatable {
    case setDefaultEditorOverride(EditorID?)
    case setWorktreeBaseDirectory(String?)
    case writeFailed(String)
    /// Replace the entire `scripts` array. The Scripts pane writes
    /// after every edit / reorder / delete; full-array semantics match
    /// `ForEach.onMove` and `SettingsWriter.setProjectScripts`.
    case setProjectScripts([ScriptDefinition])
    /// Write a single worktree-lifecycle script (setup/archive/delete).
    case setLifecycleScript(SettingsWriter.WorktreeLifecycle, String)
    /// Run a script in the resolved worktree. On `RunScriptError` the
    /// reducer surfaces the message via `.writeFailed` so the pane's
    /// existing failure banner displays it.
    case runScriptTapped(scriptID: UUID, worktreeID: WorktreeID)
    /// (Re)scan the Project's manifests for command suggestions. Sent when
    /// the Commands pane appears and from the menu's Refresh item.
    case scanCommandSuggestions
    case commandSuggestionsScanned([CommandSuggestionGroup])
  }

  nonisolated enum CancelID: Sendable { case commandSuggestionScan }

  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(FinderClient.self) var finderClient
  @Dependency(SettingsWriter.self) var settingsWriter
  @Dependency(CommandSuggestionClient.self) var commandSuggestionClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setDefaultEditorOverride(let editorID):
        let writer = settingsWriter.setProjectDefaultEditor
        return .run { [projectID = state.projectID] send in
          await writer(projectID, editorID)
          await send(.writeFailed(""))  // Clear the error on success
        }

      case .setWorktreeBaseDirectory(let path):
        let writer = settingsWriter.setProjectWorktreesDirectory
        return .run { [projectID = state.projectID] send in
          await writer(projectID, path)
          await send(.writeFailed(""))  // Clear the error on success
        }

      case .writeFailed(let message):
        state.lastWriteFailure = message.isEmpty ? nil : message
        return .none

      case .setProjectScripts(let scripts):
        let writer = settingsWriter.setProjectScripts
        return .run { [projectID = state.projectID] send in
          await writer(projectID, scripts)
          await send(.writeFailed(""))
        }

      case .setLifecycleScript(let phase, let command):
        let writer = settingsWriter.setProjectLifecycleScript
        return .run { [projectID = state.projectID] send in
          await writer(projectID, phase, command)
          await send(.writeFailed(""))
        }

      case .runScriptTapped(let scriptID, let worktreeID):
        let runner = hierarchyClient.runScript
        return .run { [projectID = state.projectID] send in
          do {
            try await runner(scriptID, projectID, worktreeID)
          } catch let error as RunScriptError {
            await send(.writeFailed(Self.runScriptErrorMessage(error)))
          } catch {
            await send(.writeFailed("Run script failed: \(error.localizedDescription)"))
          }
        }

      case .scanCommandSuggestions:
        guard let location = manifestLocation(for: state) else {
          state.commandSuggestions = []
          state.isScanningCommandSuggestions = false
          return .cancel(id: CancelID.commandSuggestionScan)
        }
        state.isScanningCommandSuggestions = true
        let scan = commandSuggestionClient.scan
        return .run { send in
          await send(.commandSuggestionsScanned(await scan(location)))
        }
        .cancellable(id: CancelID.commandSuggestionScan, cancelInFlight: true)

      case .commandSuggestionsScanned(let groups):
        state.commandSuggestions = groups
        state.isScanningCommandSuggestions = false
        return .none
      }
    }
  }

  /// Scan the checkout the user is working in — the pane's focused worktree,
  /// else the Project's selected one — since branches can carry different
  /// manifests; fall back to the Project root. Server projects read over SSH.
  private func manifestLocation(for state: State) -> ManifestLocation? {
    guard let project = hierarchyClient.snapshot().projects.first(where: { $0.id == state.projectID }) else {
      return nil
    }
    let worktreeID = state.lastFocusedWorktreeID ?? project.selectedWorktreeID
    let directory = project.worktrees.first(where: { $0.id == worktreeID })?.path ?? project.rootPath
    return ManifestLocation(directory: directory, host: project.remoteHost)
  }

  /// Human-friendly mapping for the failure banner. Mirrors
  /// `RootFeature.runScriptErrorMessage` so both surfaces phrase
  /// identical errors identically.
  static func runScriptErrorMessage(_ error: RunScriptError) -> String {
    switch error {
    case .unknownScript:
      return "That script no longer exists."
    case .missingWorktree:
      return "The worktree for this script is no longer available."
    case .missingProject:
      return "The Project for this script is no longer available."
    }
  }
}
