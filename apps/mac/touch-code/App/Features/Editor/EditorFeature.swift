import ComposableArchitecture
import Foundation
import TouchCodeCore

/// C8a editor feature. Drives the Worktree-header dropdown and the Settings default-editor
/// picker. State is a cached `describe()` result + the currently stored global default.
/// Custom-editor plumbing (add / update / remove) is gone — C8a retired `customEditors`.
///
/// Per-Project override handling lives here (not in the service): the `.openDefault…`
/// action reads `Project.defaultEditor` out of the hierarchy snapshot and folds it into the
/// `preferred` hand-off. The service itself sees only an `EditorID?`.
@Reducer
struct EditorFeature {
  @ObservableState
  struct State: Equatable {
    /// Descriptors from the last successful `describe`. Empty until first fetch.
    var descriptors: [EditorDescriptor] = []
    /// Latest global default read from `SettingsStore`. Views bind the dropdown selection
    /// to this; setters dispatch `.setGlobalDefault`.
    var globalDefault: EditorID?
    /// Monotonic counter that forces a `describe()` re-fetch on bump. Incremented by
    /// `.refreshRequested`.
    var refreshToken: Int = 0

    /// Latest outcome of a `.openRequested` effect. Views observe to render toasts.
    var lastOpenResult: OpenResultMarker?

    /// Latest per-Project override write outcome. Non-nil means "last write failed".
    var lastProjectOverrideFailure: String?
  }

  /// Test-friendly witness for editor-open outcomes.
  enum OpenResultMarker: Equatable {
    case opened(editorID: EditorID, displayName: String)
    case failed(reason: String)
  }

  enum Action: Equatable {
    /// Fired on view appear; re-fetches descriptors and reads current settings.
    case onAppear
    case refreshRequested
    case descriptorsLoaded([EditorDescriptor])
    case settingsObserved(globalDefault: EditorID?)
    case setGlobalDefault(EditorID?)
    case setProjectOverride(projectID: ProjectID, editorID: EditorID?)
    case setProjectOverrideFailed(reason: String)
    case openRequested(editorID: EditorID?, worktreePath: String, projectID: ProjectID?)
    case openSucceeded(editorID: EditorID, displayName: String)
    case openFailed(reason: String)
    /// T3 (⌘O): resolve the Worktree's default editor via per-Project override → global
    /// default → priority walk, then forward to `.openRequested` with a concrete preferred.
    case openDefaultInCurrentWorktreeRequested(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      worktreePath: String
    )
    case delegate(Delegate)

    /// Parent-consumed events. RootFeature handles `openShellEditorRequested` by
    /// spawning a Pane with `initialCommand: "$EDITOR"` — `EditorService` cannot
    /// service the shell-editor branch (no Pane/Tab context in its signature), so the
    /// reducer routes it out instead of letting `editorClient.open` throw
    /// `.launchFailed`.
    enum Delegate: Equatable {
      case openShellEditorRequested(worktreePath: String, projectID: ProjectID?)
    }
  }

  @Dependency(EditorClient.self) var editorClient
  @Dependency(HierarchyClient.self) var hierarchyClient
  @Dependency(SettingsWriter.self) var settingsWriter

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let reader = settingsWriter.readSnapshot
        return .merge(
          refresh(client: editorClient),
          .run { send in
            let snapshot = await reader()
            await send(.settingsObserved(globalDefault: snapshot.general.defaultEditorID))
          }
        )

      case .refreshRequested:
        state.refreshToken = state.refreshToken &+ 1
        let client = editorClient
        return .run { send in
          await client.clearCache()
          let descriptors = await client.describe()
          await send(.descriptorsLoaded(descriptors))
        }

      case .descriptorsLoaded(let descriptors):
        state.descriptors = descriptors
        return .none

      case .settingsObserved(let globalDefault):
        state.globalDefault = globalDefault
        return .none

      case .setGlobalDefault(let editorID):
        state.globalDefault = editorID
        let writer = settingsWriter.setDefaultEditorID
        return .run { _ in await writer(editorID) }

      case .setProjectOverride(let projectID, let editorID):
        // Per-Project editor overrides live in settings.json.projects[pid].defaultEditor.
        state.lastProjectOverrideFailure = nil
        let writer = settingsWriter.setProjectDefaultEditor
        return .run { _ in await writer(projectID, editorID) }

      case .setProjectOverrideFailed(let reason):
        state.lastProjectOverrideFailure = reason
        return .none

      case .openRequested(let editorID, let worktreePath, let projectID):
        // `.shellEditor` cannot launch through `editorClient.open` — the service
        // signature has no Pane/Tab context. Route the spawn out to `RootFeature`
        // via the delegate so it can call `hierarchyClient.openPane(...
        // initialCommand: "$EDITOR")` for the target worktree's tab.
        if editorID == EditorRegistry.shellEditorID {
          return .send(
            .delegate(
              .openShellEditorRequested(worktreePath: worktreePath, projectID: projectID)
            ))
        }
        let client = editorClient
        let url = URL(fileURLWithPath: worktreePath)
        return .run { send in
          do {
            let choice = try await client.open(url, editorID)
            await send(.openSucceeded(editorID: choice.id, displayName: choice.displayName))
          } catch let error as EditorError {
            await send(.openFailed(reason: Self.editorErrorDescription(error)))
          } catch {
            await send(.openFailed(reason: String(describing: error)))
          }
        }

      case .delegate:
        return .none

      case .openSucceeded(let id, let name):
        state.lastOpenResult = .opened(editorID: id, displayName: name)
        return .none

      case .openFailed(let reason):
        state.lastOpenResult = .failed(reason: reason)
        return .none

      case .openDefaultInCurrentWorktreeRequested(let projectID, _, let worktreePath):
        // Look up per-Project override in the catalog snapshot, then hand a nullable
        // `preferred` to the service. `resolveInstalledPreference` returns nil when
        // neither the override nor the global default resolves to an installed editor,
        // deferring to the service's priority cascade (cursor / zed / vscode / …) rather
        // than short-circuiting on Finder — otherwise a clean install with no stored
        // default would always land in Finder even if higher-priority editors are
        // installed.
        // v3 reads per-Project editor override from settings.json.projects[pid] via
        // SettingsWriter; catalog.json no longer carries Project.defaultEditor.
        let projectOverride = settingsWriter.readSnapshotSync().projects[projectID]?.defaultEditor
        let preferred = Self.resolveInstalledPreference(
          projectOverride: projectOverride,
          globalDefault: state.globalDefault,
          descriptors: state.descriptors
        )
        return .send(
          .openRequested(
            editorID: preferred,
            worktreePath: worktreePath,
            projectID: projectID
          ))
      }
    }
  }

  /// Built-in Finder `EditorID`. Aliased from `EditorRegistry.finderID` so callers that
  /// need the always-installed fallback don't hand-roll the string literal.
  nonisolated static let finderEditorID: EditorID = EditorRegistry.finderID

  /// Result of resolving the Worktree's default editor for the Header "Open" primary
  /// action. Cascade-on-missing: an override id that's absent from `descriptors` does not
  /// strand the user on Finder when a global default is installed.
  nonisolated enum ResolvedDefault: Equatable {
    case editor(EditorDescriptor)
    case finder
  }

  nonisolated static func resolveDefault(
    projectOverride: EditorID?,
    globalDefault: EditorID?,
    descriptors: [EditorDescriptor]
  ) -> ResolvedDefault {
    if let override = projectOverride,
      let match = descriptors.first(where: { $0.id == override })
    {
      return .editor(match)
    }
    if let global = globalDefault,
      let match = descriptors.first(where: { $0.id == global })
    {
      return .editor(match)
    }
    // Mirror the service-side priority walk so the label matches what the
    // primary tap will actually open. Without this, the chip says "Finder"
    // while clicking it opens, say, Cursor (RootFeature.openEditor → service
    // cascade through EditorRegistry.defaultPriority).
    let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    for id in EditorRegistry.defaultPriority {
      if let match = byID[id] {
        return .editor(match)
      }
    }
    return .finder
  }

  /// Reducer-side resolver for the `preferred` argument handed to `EditorService.open`.
  /// Returns the project override (if installed), else the global default (if installed),
  /// else **nil** — handing off to the service's priority cascade. Never materializes a
  /// Finder fallback: that would bypass higher-priority installed editors (e.g. on a clean
  /// install with Cursor present but no stored default, forcing `"finder"` here would
  /// short-circuit the priority walk before Cursor is ever considered, because the
  /// service's "preferred" tier is strict — a Finder `preferred` returns Finder).
  ///
  /// Callers: `EditorFeature.openDefaultInCurrentWorktreeRequested`,
  /// `RootFeature.sidebar(.delegate(.openInDefaultEditor))`,
  /// `RootFeature.worktreeHeader(.delegate(.openEditor))`,
  /// `GitViewerFeature.editorOpenRequest`.
  nonisolated static func resolveInstalledPreference(
    projectOverride: EditorID?,
    globalDefault: EditorID?,
    descriptors: [EditorDescriptor]
  ) -> EditorID? {
    if let override = projectOverride,
      descriptors.contains(where: { $0.id == override })
    {
      return override
    }
    if let global = globalDefault,
      descriptors.contains(where: { $0.id == global })
    {
      return global
    }
    return nil
  }

  /// Human-readable reason for an `EditorError`, surfaced as a toast subtitle by views.
  nonisolated static func editorErrorDescription(_ error: EditorError) -> String {
    switch error {
    case .notInstalled(let id, _):
      return "\(id) is not installed"
    case .launchFailed(let reason):
      return "Could not launch editor: \(reason)"
    case .notADirectory(let path):
      return "Not a directory: \(path)"
    }
  }

  private func refresh(client: EditorClient) -> Effect<Action> {
    .run { send in
      let descriptors = await client.describe()
      await send(.descriptorsLoaded(descriptors))
    }
  }
}

// MARK: - SettingsWriter dependency

/// Narrow dependency over `SettingsStore`. Carries the global editor-default writer plus
/// per-Project writers for the two fields that v3 settings.json absorbed from catalog.json
/// (`defaultEditor`, `worktreesDirectory`). Features call these closures instead of
/// reaching into `SettingsStore` directly so tests can override writes without a
/// `@MainActor` ceremony.
nonisolated struct SettingsWriter: Sendable {
  /// Worktree-lifecycle phase identifying which `GitProjectSettings.*Script`
  /// to mutate.
  enum WorktreeLifecycle: Sendable, Equatable, Hashable {
    case setup
    case archive
    case delete
  }

  /// Identifies a single mutable field under `ProjectSettings.git`. Carrying
  /// the new value inline keeps the closure count manageable while still
  /// letting tests assert specific writes.
  enum GitFieldUpdate: Sendable, Equatable {
    case worktreeBaseRef(String?)
    case copyIgnoredOnWorktreeCreate(Bool?)
    case copyUntrackedOnWorktreeCreate(Bool?)
    case defaultMergeStrategy(MergeStrategy?)
    case postMergeAction(MergedWorktreeAction?)
    case githubDisabled(Bool)
  }

  var readSnapshot: @Sendable () async -> Settings
  /// Synchronous snapshot read. Implementation walks the `@MainActor` `SettingsStore`
  /// under `MainActor.assumeIsolated` so reducers already on the main queue can read
  /// without an async hop. Safe for the TCA reducers in this app (they all run on
  /// MainActor); crashes in debug if called off the main actor.
  var readSnapshotSync: @Sendable () -> Settings
  var setDefaultEditorID: @Sendable (EditorID?) async -> Void
  /// Per-Project editor override. `nil` clears.
  var setProjectDefaultEditor: @Sendable (_ projectID: ProjectID, _ editorID: EditorID?) async -> Void
  /// Per-Project Git Viewer override. `nil` clears (inherit
  /// `GeneralSettings.defaultGitViewerID`); `.builtin` forces the in-app
  /// overlay; `.external(id)` opens the named git client.
  var setProjectDefaultGitViewer:
    @Sendable (_ projectID: ProjectID, _ override: ProjectGitViewerPreference?) async -> Void
  /// Per-Project worktree base directory override. `nil` clears.
  var setProjectWorktreesDirectory: @Sendable (_ projectID: ProjectID, _ path: String?) async -> Void

  /// Per-Project mutation of a specific git-subtree field. The closure
  /// ensures `git` is non-nil before applying the field write and runs
  /// `collapseEmptyGit()` after so an all-default git child collapses
  /// to nil before persistence.
  var setProjectGitField: @Sendable (_ projectID: ProjectID, _ update: GitFieldUpdate) async -> Void

  /// Per-Project envVars mutation. `value: nil` removes the key; `""` stores
  /// an empty-string value.
  var setProjectEnvVar: @Sendable (_ projectID: ProjectID, _ key: String, _ value: String?) async -> Void

  /// Per-Project scripts replace. The Scripts pane writes the full array
  /// after every edit / reorder / delete; this is simpler than per-script
  /// upsert closures and matches `ForEach.onMove`'s array-back semantics.
  var setProjectScripts: @Sendable (_ projectID: ProjectID, _ scripts: [ScriptDefinition]) async -> Void

  /// Per-Project worktree-lifecycle script. Empty string clears.
  var setProjectLifecycleScript:
    @Sendable (_ projectID: ProjectID, _ phase: WorktreeLifecycle, _ command: String) async -> Void
}

extension SettingsWriter {
  @MainActor
  static func live(_ store: SettingsStore) -> SettingsWriter {
    SettingsWriter(
      readSnapshot: { [weak store] in
        await MainActor.run { store?.settings ?? .default }
      },
      readSnapshotSync: { [weak store] in
        MainActor.assumeIsolated { store?.settings ?? .default }
      },
      setDefaultEditorID: { [weak store] id in
        await MainActor.run { store?.setDefaultEditorID(id) }
      },
      setProjectDefaultEditor: { [weak store] pid, id in
        await MainActor.run {
          store?.mutateProject(pid) { $0.defaultEditor = id }
        }
      },
      setProjectDefaultGitViewer: { [weak store] pid, override in
        await MainActor.run {
          store?.mutateProject(pid) { $0.defaultGitViewer = override }
        }
      },
      setProjectWorktreesDirectory: { [weak store] pid, path in
        await MainActor.run {
          store?.mutateProject(pid) { $0.worktreesDirectory = path }
        }
      },
      setProjectGitField: { [weak store] pid, update in
        await MainActor.run {
          store?.mutateProject(pid) { project in
            var git = project.git ?? GitProjectSettings()
            switch update {
            case .worktreeBaseRef(let value):
              git.worktreeBaseRef = value
            case .copyIgnoredOnWorktreeCreate(let value):
              git.copyIgnoredOnWorktreeCreate = value
            case .copyUntrackedOnWorktreeCreate(let value):
              git.copyUntrackedOnWorktreeCreate = value
            case .defaultMergeStrategy(let value):
              git.defaultMergeStrategy = value
            case .postMergeAction(let value):
              git.postMergeAction = value
            case .githubDisabled(let value):
              git.githubDisabled = value
            }
            project.git = git
            project.collapseEmptyGit()
          }
        }
      },
      setProjectEnvVar: { [weak store] pid, key, value in
        await MainActor.run {
          store?.mutateProject(pid) { project in
            if let value {
              project.envVars[key] = value
            } else {
              project.envVars.removeValue(forKey: key)
            }
          }
        }
      },
      setProjectScripts: { [weak store] pid, scripts in
        await MainActor.run {
          store?.mutateProject(pid) { $0.scripts = scripts }
        }
      },
      setProjectLifecycleScript: { [weak store] pid, phase, command in
        await MainActor.run {
          store?.mutateProject(pid) { project in
            var git = project.git ?? GitProjectSettings()
            // Empty `command` clears the slot back to nil; otherwise carry
            // forward the existing ScriptDefinition (preserves UUID + any
            // adjacent fields) and update its `command`.
            func updated(_ existing: ScriptDefinition?) -> ScriptDefinition? {
              guard !command.isEmpty else { return nil }
              var def = existing ?? ScriptDefinition()
              def.command = command
              return def
            }
            switch phase {
            case .setup:
              git.createScript = updated(git.createScript)
            case .archive:
              git.archiveScript = updated(git.archiveScript)
            case .delete:
              git.deleteScript = updated(git.deleteScript)
            }
            project.git = git
            project.collapseEmptyGit()
          }
        }
      }
    )
  }
}

extension SettingsWriter: DependencyKey {
  static let liveValue: SettingsWriter = SettingsWriter(
    readSnapshot: {
      fatalError("SettingsWriter.liveValue not configured; wire via `.withDependencies` at app startup")
    },
    readSnapshotSync: { fatalError("SettingsWriter.liveValue not configured") },
    setDefaultEditorID: { _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectDefaultEditor: { _, _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectDefaultGitViewer: { _, _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectWorktreesDirectory: { _, _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectGitField: { _, _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectEnvVar: { _, _, _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectScripts: { _, _ in fatalError("SettingsWriter.liveValue not configured") },
    setProjectLifecycleScript: { _, _, _ in fatalError("SettingsWriter.liveValue not configured") }
  )

  static let testValue: SettingsWriter = SettingsWriter(
    readSnapshot: unimplemented("SettingsWriter.readSnapshot", placeholder: .default),
    readSnapshotSync: unimplemented("SettingsWriter.readSnapshotSync", placeholder: .default),
    setDefaultEditorID: unimplemented("SettingsWriter.setDefaultEditorID"),
    setProjectDefaultEditor: unimplemented("SettingsWriter.setProjectDefaultEditor"),
    setProjectDefaultGitViewer: unimplemented("SettingsWriter.setProjectDefaultGitViewer"),
    setProjectWorktreesDirectory: unimplemented("SettingsWriter.setProjectWorktreesDirectory"),
    setProjectGitField: unimplemented("SettingsWriter.setProjectGitField"),
    setProjectEnvVar: unimplemented("SettingsWriter.setProjectEnvVar"),
    setProjectScripts: unimplemented("SettingsWriter.setProjectScripts"),
    setProjectLifecycleScript: unimplemented("SettingsWriter.setProjectLifecycleScript")
  )
}

extension DependencyValues {
  var settingsWriter: SettingsWriter {
    get { self[SettingsWriter.self] }
    set { self[SettingsWriter.self] = newValue }
  }
}
