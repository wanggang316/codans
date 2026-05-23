import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project General detail pane — Phase 2 5-Section Form.
///
/// Five sibling Sections in fixed order: Editor, Default Shell, Worktree,
/// GitHub, Environment. Worktree and GitHub render only when
/// `ProjectKind == .gitRepo`; the design doc's "kind drives sections, not
/// labels" rule means we never paint a "this is a git repo" affordance —
/// the sections simply appear or don't.
///
/// All writes route through `SettingsWriter` closures injected on the
/// dependency, so tests can intercept individual fields without
/// instantiating a `SettingsStore`. Reads come from
/// `@Environment(SettingsStore.self)` for live updates and from the local
/// `ProjectSettingsFeature.State` for kind / lastWriteFailure.
struct ProjectGeneralSettingsView: View {
  let projectID: ProjectID
  let store: StoreOf<ProjectSettingsFeature>
  let descriptors: [EditorDescriptor]

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore
  @Dependency(SettingsWriter.self) private var settingsWriter
  @Dependency(GitWorktreeClient.self) private var gitWorktreeClient

  /// Branches loaded from the repo on view appearance. `baseRefOptions` is
  /// `git for-each-ref refs/heads refs/remotes` output (local + remote
  /// branches, HEAD aliases stripped); `defaultRemoteBaseRef` is the
  /// resolved `origin/HEAD` and seeds the "Auto" inherit row label.
  /// `baseRefOptionsLoaded` flips true after the first async load completes so
  /// the inherit row can render "Global" until then — avoids the
  /// "Global — origin/HEAD" → "Global — origin/main" flicker that shows up
  /// when the picker paints before `defaultRemoteBranchRef` returns.
  @State private var baseRefOptions: [String] = []
  @State private var defaultRemoteBaseRef: String?
  @State private var baseRefOptionsLoaded: Bool = false

  /// IDs for the six Sections — useful for the kind-render tests so they
  /// can assert visibility without inspecting SwiftUI's view tree.
  enum SectionID: String, CaseIterable, Hashable {
    case editor
    case gitViewer
    case defaultShell
    case worktree
    case github
    case environment
  }

  /// Pure visibility logic. Git Viewer / Worktree / GitHub gate on
  /// `kind == .gitRepo`; everything else is always visible.
  nonisolated static func visibleSections(for kind: ProjectKind) -> Set<SectionID> {
    switch kind {
    case .dir:
      return [.editor, .defaultShell, .environment]
    case .gitRepo:
      return Set(SectionID.allCases)
    }
  }

  /// Captures the per-control write fan-out as plain `@Sendable` closures so
  /// the binding bodies stay short and tests can hit each route without
  /// instantiating the SwiftUI view. Each method below mirrors the body of
  /// the corresponding `Binding(set:)` in the rendered view; the bindings
  /// delegate here so the routing logic has a single home.
  struct WriteRoutes: Sendable {
    let projectID: ProjectID
    let writer: SettingsWriter

    func writeDefaultEditor(_ value: EditorID?) {
      let setter = writer.setProjectDefaultEditor
      Task { await setter(projectID, value) }
    }

    func writeDefaultGitViewer(_ value: ProjectGitViewerPreference?) {
      let setter = writer.setProjectDefaultGitViewer
      Task { await setter(projectID, value) }
    }

    func writeDefaultShell(_ value: String?) {
      let setter = writer.setProjectDefaultShell
      Task { await setter(projectID, value) }
    }

    func writeWorktreeBaseRef(_ rawValue: String) {
      let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let payload: String? = trimmed.isEmpty ? nil : trimmed
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .worktreeBaseRef(payload)) }
    }

    func writeCopyIgnored(_ value: Bool?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .copyIgnoredOnWorktreeCreate(value)) }
    }

    func writeCopyUntracked(_ value: Bool?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .copyUntrackedOnWorktreeCreate(value)) }
    }

    func writeMergeStrategy(_ value: MergeStrategy?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .defaultMergeStrategy(value)) }
    }

    func writePostMergeAction(_ value: MergedWorktreeAction?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .postMergeAction(value)) }
    }

    func writeGithubDisabled(_ value: Bool) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .githubDisabled(value)) }
    }

    func writeEnvVar(key: String, value: String?) {
      let setter = writer.setProjectEnvVar
      Task { await setter(projectID, key, value) }
    }
  }

  private var routes: WriteRoutes {
    WriteRoutes(projectID: projectID, writer: settingsWriter)
  }

  private var visible: Set<SectionID> {
    Self.visibleSections(for: store.state.kind)
  }

  private var entry: ProjectSettings? {
    settingsStore.settings.projects[projectID]
  }

  private var general: GeneralSettings {
    settingsStore.settings.general
  }

  var body: some View {
    Form {
      if visible.contains(.editor) {
        editorSection
      }
      if visible.contains(.gitViewer) {
        gitViewerSection
      }
      if visible.contains(.defaultShell) {
        defaultShellSection
      }
      if visible.contains(.worktree) {
        worktreeSection
      }
      if visible.contains(.github) {
        githubSection
      }
      if visible.contains(.environment) {
        environmentSection
      }

      if let error = store.state.lastWriteFailure, !error.isEmpty {
        Section {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .foregroundColor(.red)
        }
      }
    }
    .formStyle(.grouped)
    .task(id: projectID) { await loadBaseRefOptionsIfNeeded() }
  }

  /// Loads local + remote refs and the remote default once per pane
  /// materialisation. Cheap (`git for-each-ref` + `symbolic-ref`); skipping
  /// on dir Projects keeps non-git Projects from shelling out.
  private func loadBaseRefOptionsIfNeeded() async {
    guard visible.contains(.worktree),
      let gitRoot = hierarchyManager.catalog.projects
        .first(where: { $0.id == projectID })?.gitRoot
    else { return }
    let repoRoot = URL(fileURLWithPath: gitRoot)
    async let refs = (try? gitWorktreeClient.branchRefs(repoRoot)) ?? []
    async let auto = (try? gitWorktreeClient.defaultRemoteBranchRef(repoRoot)) ?? nil
    let loadedRefs = await refs
    let loadedAuto = await auto
    baseRefOptions = loadedRefs
    defaultRemoteBaseRef = loadedAuto
    baseRefOptionsLoaded = true
  }

  // MARK: - Editor

  /// Visually mirrors Settings → General → Default editor and the Worktree-header
  /// "Open in" submenu: a flat priority-ordered list rendered through
  /// `EditorPickerRow.row(for:)` so every editor dropdown across the app has the same
  /// icon + displayName row. The leading sentinel reuses
  /// `OptionalOverridePicker.inheritRowText` so the "Global — <name>" composition
  /// stays in one place.
  @ViewBuilder
  private var editorSection: some View {
    Section("Editor") {
      Picker("Default editor", selection: editorBinding) {
        Text(editorInheritRowText)
          .tag(EditorID?.none)
        ForEach(Array(EditorPickerRow.sortedGroups(descriptors).enumerated()), id: \.offset) { _, group in
          Section {
            ForEach(group, id: \.id) { descriptor in
              EditorPickerRow.row(for: descriptor)
                .tag(EditorID?(descriptor.id))
            }
          }
        }
      }
      .pickerStyle(.menu)
    }
  }

  private var editorInheritRowText: String {
    OptionalOverridePicker<EditorID>.inheritRowText(
      inheritedLabel: { id in
        guard let id else { return "Auto" }
        return descriptors.first(where: { $0.id == id })?.displayName ?? id
      },
      inheritedValue: general.defaultEditorID
    )
  }

  private var editorBinding: Binding<EditorID?> {
    Binding(
      get: { entry?.defaultEditor },
      set: { routes.writeDefaultEditor($0) }
    )
  }

  // MARK: - Git Viewer

  /// Per-Project Git Viewer override. Three states surfaced as one picker:
  ///   1. **Global — &lt;name&gt;** (tag `nil`): inherit
  ///      `GeneralSettings.defaultGitViewerID`.
  ///   2. **Built-in** (tag `.builtin`): force the in-app overlay even if
  ///      the global default is an external client.
  ///   3. Any installed git client (tag `.external(id)`): open the worktree
  ///      in that app on ⌘⌥G.
  ///
  /// Mirrors the Settings → General → Default Git Viewer dropdown but adds
  /// the inherit sentinel that every other per-Project override in this
  /// view uses.
  @ViewBuilder
  private var gitViewerSection: some View {
    Section("Git Viewer") {
      Picker("Default Git Viewer", selection: gitViewerBinding) {
        Text(gitViewerInheritRowText)
          .tag(ProjectGitViewerPreference?.none)
        Label {
          Text("Built-in")
        } icon: {
          Image(systemName: "doc.text.magnifyingglass")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
        .tag(ProjectGitViewerPreference?(.builtin))

        if !installedGitClients.isEmpty {
          Section {
            ForEach(installedGitClients, id: \.id) { descriptor in
              EditorPickerRow.row(for: descriptor)
                .tag(ProjectGitViewerPreference?(.external(descriptor.id)))
            }
          }
        }
      }
      .pickerStyle(.menu)
    }
  }

  /// Composes the "Global — &lt;X&gt;" sentinel label. Resolves the inherited id
  /// against the current `descriptors` list so the label shows the actual
  /// client displayName (or "Built-in" when nothing is set).
  private var gitViewerInheritRowText: String {
    let inheritedLabel: String = {
      guard let id = general.defaultGitViewerID else { return "Built-in" }
      return descriptors.first(where: { $0.id == id })?.displayName ?? id
    }()
    return "Global — \(inheritedLabel)"
  }

  /// Installed git clients, filtered by `EditorRegistry.gitClientPriority`
  /// in canonical priority order. Same source the Settings → General picker
  /// uses so both surfaces stay in sync without a shared helper.
  private var installedGitClients: [EditorDescriptor] {
    let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    return EditorRegistry.gitClientPriority.compactMap { byID[$0] }
  }

  private var gitViewerBinding: Binding<ProjectGitViewerPreference?> {
    Binding(
      get: { entry?.defaultGitViewer },
      set: { routes.writeDefaultGitViewer($0) }
    )
  }

  // MARK: - Default Shell

  @ViewBuilder
  private var defaultShellSection: some View {
    Section("Default Shell") {
      OptionalOverridePicker<String>(
        title: "Shell",
        selection: shellBinding,
        // GeneralSettings.defaultShell does not exist today — when a future
        // wave adds it, swap this literal for the real field. The live
        // resolved-shell logic across the app already falls back to
        // /bin/zsh, so the inherit row label matches the runtime default.
        inheritedValue: "/bin/zsh",
        options: shellOptions,
        inheritedLabel: { value in value ?? "/bin/zsh" }
      )
    }
  }

  private var shellOptions: [OptionalOverridePicker<String>.Option] {
    ShellRegistry.installed.map { path in
      .init(value: path, label: path)
    }
  }

  private var shellBinding: Binding<String?> {
    Binding(
      get: { entry?.defaultShell },
      set: { routes.writeDefaultShell($0) }
    )
  }

  // MARK: - Worktree

  @ViewBuilder
  private var worktreeSection: some View {
    Section("Worktree") {
      LabeledContent("Worktree Directory") {
        HStack(spacing: 6) {
          // Right-aligned to match the rest of the Form's value column —
          // Pickers and Toggles in this Section already trail-align, so a
          // forced .leading frame here was the odd one out.
          Text(entry?.worktreesDirectory ?? defaultWorktreesDirectory)
            .foregroundStyle(entry?.worktreesDirectory == nil ? .secondary : .primary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .trailing)
          Button {
            chooseWorktreeDirectory()
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help("Choose a different directory…")
          if entry?.worktreesDirectory != nil {
            Button {
              store.send(.setWorktreeBaseDirectory(nil))
            } label: {
              Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
          }
        }
      }

      worktreeBaseRefPicker

      TriStateOverrideToggle(
        title: "Copy .gitignore'd files",
        selection: copyIgnoredBinding,
        inheritedValue: settingsStore.settings.worktree.copyIgnoredOnCreate
      )
      TriStateOverrideToggle(
        title: "Copy untracked files",
        selection: copyUntrackedBinding,
        inheritedValue: settingsStore.settings.worktree.copyUntrackedOnCreate
      )
    }
  }

  /// Fallback shown when the project has no `worktreesDirectory` override —
  /// matches the runtime fallback computed in `HierarchySidebarFeature` when
  /// opening the Create Worktree sheet. Routes through
  /// `WorktreeSettings.resolveBaseDirectory` so the inherited preview tracks
  /// any change to the global default.
  private var defaultWorktreesDirectory: String {
    let projectName =
      hierarchyManager.catalog.projects.first(where: { $0.id == projectID })?.name ?? "<project>"
    return settingsStore.settings.worktree
      .resolveBaseDirectory(forProjectName: projectName, projectOverride: nil)
      .path(percentEncoded: false)
  }

  /// Dropdown for the per-Project Worktree base ref. `nil` = inherit (use
  /// the remote default). Options group local branches (refs/heads) and
  /// remote branches (refs/remotes/<remote>/…) so the menu reads like the
  /// Create Worktree sheet's base-ref picker.
  @ViewBuilder
  private var worktreeBaseRefPicker: some View {
    Picker("Base ref", selection: worktreeBaseRefBinding) {
      Text(baseRefInheritRowText).tag(String?.none)
      let groups = groupedBaseRefOptions
      if !groups.local.isEmpty {
        Section("Local") {
          ForEach(groups.local, id: \.self) { ref in
            Text(ref).tag(String?(ref))
          }
        }
      }
      if !groups.remote.isEmpty {
        Section("Remote") {
          ForEach(groups.remote, id: \.self) { ref in
            Text(ref).tag(String?(ref))
          }
        }
      }
      // A persisted override may point at a ref that no longer exists
      // (deleted branch). Render it so the picker can display the current
      // selection rather than silently flipping to nil.
      if let override = entry?.git?.worktreeBaseRef,
        !override.isEmpty,
        !baseRefOptions.contains(override)
      {
        Section("Unknown") {
          Text("\(override) (missing)").tag(String?(override))
        }
      }
    }
    .pickerStyle(.menu)
  }

  private var baseRefInheritRowText: String {
    // While the async load is in flight, return a bare "Global" rather than
    // the "origin/HEAD" placeholder — otherwise the picker briefly shows
    // "Global — origin/HEAD" and then snaps to the resolved branch.
    OptionalOverridePicker<String>.inheritRowText(
      inheritedLabel: { baseRefOptionsLoaded ? ($0 ?? "origin/HEAD") : "" },
      inheritedValue: defaultRemoteBaseRef
    )
  }

  /// Partitions `baseRefOptions` into local (refs/heads) and remote
  /// (refs/remotes/<remote>/…) sets. Heuristic: refs containing a `/` whose
  /// first segment is a known remote prefix go to remote; everything else
  /// is treated as local. We don't have the remote list cheaply here, so
  /// the convention "first segment matches `origin` or `upstream` or any
  /// segment ending in `/HEAD`" is sufficient; everything else falls back
  /// to local.
  private var groupedBaseRefOptions: (local: [String], remote: [String]) {
    var local: [String] = []
    var remote: [String] = []
    for ref in baseRefOptions {
      if ref.contains("/") {
        remote.append(ref)
      } else {
        local.append(ref)
      }
    }
    return (local, remote)
  }

  private var worktreeBaseRefBinding: Binding<String?> {
    Binding(
      get: { entry?.git?.worktreeBaseRef },
      set: { routes.writeWorktreeBaseRef($0 ?? "") }
    )
  }

  private var copyIgnoredBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.copyIgnoredOnWorktreeCreate },
      set: { routes.writeCopyIgnored($0) }
    )
  }

  private var copyUntrackedBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.copyUntrackedOnWorktreeCreate },
      set: { routes.writeCopyUntracked($0) }
    )
  }

  // MARK: - GitHub

  @ViewBuilder
  private var githubSection: some View {
    Section("GitHub") {
      OptionalOverridePicker<MergeStrategy>(
        title: "Merge strategy",
        selection: mergeStrategyBinding,
        inheritedValue: general.defaultMergeStrategy,
        options: MergeStrategy.allCases.map {
          .init(value: $0, label: $0.displayName)
        },
        inheritedLabel: { value in
          (value ?? .squash).displayName
        }
      )

      OptionalOverridePicker<MergedWorktreeAction>(
        title: "After merging a PR",
        selection: postMergeActionBinding,
        inheritedValue: general.postMergeAction,
        options: MergedWorktreeAction.allCases.map {
          .init(value: $0, label: $0.displayName)
        },
        inheritedLabel: { value in
          (value ?? .ask).displayName
        }
      )

      Toggle("Disable GitHub integration for this Project", isOn: githubDisabledBinding)
    }
  }

  private var mergeStrategyBinding: Binding<MergeStrategy?> {
    Binding(
      get: { entry?.git?.defaultMergeStrategy },
      set: { routes.writeMergeStrategy($0) }
    )
  }

  private var postMergeActionBinding: Binding<MergedWorktreeAction?> {
    Binding(
      get: { entry?.git?.postMergeAction },
      set: { routes.writePostMergeAction($0) }
    )
  }

  private var githubDisabledBinding: Binding<Bool> {
    Binding(
      get: { entry?.git?.githubDisabled ?? false },
      set: { routes.writeGithubDisabled($0) }
    )
  }

  // MARK: - Environment

  @ViewBuilder
  private var environmentSection: some View {
    Section("Environment") {
      EnvironmentEditorView(
        envVars: envVarsBinding,
        onChange: { key, newValue in
          routes.writeEnvVar(key: key, value: newValue)
        },
        footer:
          "Values are stored in plain text in settings.json. Do not paste credentials "
          + "you wouldn't keep in a config file."
      )
    }
  }

  private var envVarsBinding: Binding<[String: String]> {
    Binding(
      get: { entry?.envVars ?? [:] },
      // Writes always fan out through `onChange` per row; the @Binding setter
      // is wired so SwiftUI's diff detects mutations from the parent without
      // a separate write path.
      set: { _ in }
    )
  }

  // MARK: - Helpers

  private func chooseWorktreeDirectory() {
    let pane = NSOpenPanel()
    pane.canChooseDirectories = true
    pane.canChooseFiles = false
    pane.allowsMultipleSelection = false
    pane.message = "Choose a directory for worktree storage"
    pane.begin { response in
      if response == .OK, let url = pane.urls.first {
        store.send(.setWorktreeBaseDirectory(url.path))
      }
    }
  }
}
