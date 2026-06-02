import AppKit
import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// Project General detail pane.
///
/// Sibling Sections rendered in fixed order: Editor, Worktree, GitHub,
/// Environment. Worktree and GitHub render only when
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
  @Dependency(HierarchyClient.self) private var hierarchyClient
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

  /// IDs for the Sections — useful for the kind-render tests so they
  /// can assert visibility without inspecting SwiftUI's view tree.
  enum SectionID: String, CaseIterable, Hashable {
    case general
    case editor
    case worktree
    case github
    case environment
    case lifecycle
  }

  /// Pure visibility logic. Worktree / GitHub / Lifecycle gate
  /// on `kind == .gitRepo`; everything else is always visible.
  nonisolated static func visibleSections(for kind: ProjectKind) -> Set<SectionID> {
    switch kind {
    case .dir:
      return [.general, .editor, .environment]
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

    func writeFetchRemote(_ value: Bool?) {
      let setter = writer.setProjectGitField
      Task { await setter(projectID, .fetchRemoteOnWorktreeCreate(value)) }
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

  private var git: GitProjectSettings {
    entry?.git ?? GitProjectSettings()
  }

  var body: some View {
    Form {
      if visible.contains(.general) {
        generalSection
      }
      if visible.contains(.editor) {
        editorSection
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
      if visible.contains(.lifecycle) {
        lifecycleSections
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

  // MARK: - General

  /// Project identity — Title and Color. Writes go through `HierarchyClient`
  /// because the underlying data lives on `Project` in the catalog, not in
  /// `settings.json`. Empty / whitespace-only titles revert silently to the
  /// last accepted name so the catalog never ends up with a blank entry.
  /// Color is an inline swatch row (No Color + seven named entries) plus a
  /// system `ColorPicker` that opens NSColorPanel for arbitrary hex.
  @ViewBuilder
  private var generalSection: some View {
    Section("General") {
      LabeledContent("Name") {
        ProjectNameField(
          placeholder: projectCanonicalName,
          currentOverride: projectDisplayOverride,
          commit: { newName in
            try? hierarchyClient.renameProject(projectID, newName)
          }
        )
        .frame(maxWidth: .infinity, minHeight: 22)
      }

      LabeledContent("Color") {
        ProjectColorSwatchRow(selection: projectColorBinding)
      }
    }
  }

  /// Path-derived canonical name. Shown as the field's placeholder so the
  /// user can always see what the project would fall back to if they cleared
  /// their override. Also feeds the worktree-path preview, so renames stay
  /// purely cosmetic.
  private var projectCanonicalName: String {
    hierarchyManager.catalog.projects.first(where: { $0.id == projectID })?.canonicalName ?? ""
  }

  /// User-set display override or `nil` when the project is using the
  /// canonical name. Drives the field's initial value so a user re-opening
  /// Settings on a customized project sees their override, not the placeholder.
  private var projectDisplayOverride: String? {
    hierarchyManager.catalog.projects.first(where: { $0.id == projectID })?.displayName
  }

  private var projectColorBinding: Binding<ProjectColor?> {
    Binding(
      get: {
        hierarchyManager.catalog.projects.first(where: { $0.id == projectID })?.color
      },
      set: { newValue in
        try? hierarchyClient.setProjectColor(projectID, newValue)
      }
    )
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
        title: "Fetch remote before creating worktree",
        selection: fetchRemoteBinding,
        inheritedValue: settingsStore.settings.worktree.fetchRemoteOnCreate
      )
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
  /// any change to the global default. Anchored on the canonical name so
  /// renaming the project never moves where new worktrees would land.
  private var defaultWorktreesDirectory: String {
    let canonical =
      hierarchyManager.catalog.projects.first(where: { $0.id == projectID })?.canonicalName
      ?? "<project>"
    return settingsStore.settings.worktree
      .resolveBaseDirectory(forProjectName: canonical, projectOverride: nil)
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

  private var fetchRemoteBinding: Binding<Bool?> {
    Binding(
      get: { entry?.git?.fetchRemoteOnWorktreeCreate },
      set: { routes.writeFetchRemote($0) }
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
    Section {
      EnvironmentEditorView(
        envVars: envVarsBinding,
        builtins: BuiltinEnvVar.allCases,
        onChange: { key, newValue in
          routes.writeEnvVar(key: key, value: newValue)
        }
      )
    } header: {
      Text("Environment Variables")
    } footer: {
      Text(
        "TOUCHCODE_WORKTREE_PATH and TOUCHCODE_ROOT_PATH are provided automatically for "
          + "every pane. Values are stored in plain text in settings.json — don't paste "
          + "credentials you wouldn't keep in a config file."
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

  // MARK: - Worktree Lifecycle Scripts

  /// Git-only lifecycle script editors (Setup / Archive / Delete) rendered at
  /// the bottom of the pane. Each is one body of shell text run at the
  /// corresponding worktree phase. Writes route through the shared reducer
  /// (`setLifecycleScript`), whose debounced disk write coalesces keystrokes.
  @ViewBuilder
  private var lifecycleSections: some View {
    lifecycleSection(
      title: "Setup Script",
      subtitle: "Runs after a new worktree is created.",
      icon: "truck.box.badge.clock",
      iconColor: .blue,
      example: "pnpm install",
      text: git.createScript?.command ?? "",
      phase: .setup
    )
    lifecycleSection(
      title: "Archive Script",
      subtitle: "Runs before a worktree is archived.",
      icon: "archivebox",
      iconColor: .orange,
      example: "docker compose down",
      text: git.archiveScript?.command ?? "",
      phase: .archive
    )
    lifecycleSection(
      title: "Delete Script",
      subtitle: "Runs before a worktree is removed (files still on disk).",
      icon: "trash",
      iconColor: .red,
      example: "docker compose down",
      text: git.deleteScript?.command ?? "",
      phase: .delete
    )
  }

  @ViewBuilder
  private func lifecycleSection(
    title: String,
    subtitle: String,
    icon: String,
    iconColor: Color,
    example: String,
    text: String,
    phase: SettingsWriter.WorktreeLifecycle
  ) -> some View {
    Section {
      LifecycleEditor(
        initial: text,
        onCommit: { newValue in
          store.send(.setLifecycleScript(phase, newValue))
        }
      )
    } header: {
      Label {
        VStack(alignment: .leading, spacing: 0) {
          Text(title)
            .font(.body)
            .bold()
            .lineLimit(1)
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } icon: {
        Image(systemName: icon)
          .foregroundStyle(iconColor)
          .accessibilityHidden(true)
      }
      .labelStyle(.lifecycleSectionHeader)
    } footer: {
      Text("e.g., `\(example)`")
    }
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

/// Native `NSTextField`-backed name editor. SwiftUI's `TextField` with
/// `.textFieldStyle(.plain)` in a Form keeps showing a blinking caret after
/// outside clicks (Form's empty area doesn't propagate as a focus event),
/// so we drop down to AppKit for reliable "click anywhere → resign first
/// responder → commit" semantics.
///
/// The field surfaces the project's `displayName` override directly: when
/// the project carries a custom name, the field starts pre-filled with it
/// so the user can edit in place; when there is no override the field is
/// empty and the canonical name acts as the placeholder hint.
///
/// Commit fires on every keystroke (via `controlTextDidChange`) so the
/// sidebar / Settings sidebar / window header pick up the new name as
/// soon as the user types. Trimming + canonical-equality collapse to a
/// `nil` override lives in `HierarchyManager.renameProject`, so an empty
/// or whitespace-only field naturally reverts to the canonical name on
/// each keystroke.
private struct ProjectNameField: NSViewRepresentable {
  let placeholder: String
  let currentOverride: String?
  let commit: (String) -> Void

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.alignment = .right
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.placeholderString = placeholder
    field.stringValue = currentOverride ?? ""
    field.cell?.usesSingleLineMode = true
    field.cell?.lineBreakMode = .byTruncatingTail
    field.delegate = context.coordinator
    context.coordinator.lastAcceptedOverride = currentOverride
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    if field.placeholderString != placeholder {
      field.placeholderString = placeholder
    }
    context.coordinator.commit = commit
    // Resync the field's stringValue with the catalog's current override
    // when the user is not actively editing — otherwise an external rename
    // (or our own commit) would race with their typing. `currentEditor()`
    // is non-nil exactly when the field holds first-responder status.
    let isEditing = field.currentEditor() != nil
    if !isEditing,
      context.coordinator.lastAcceptedOverride != currentOverride
    {
      field.stringValue = currentOverride ?? ""
      context.coordinator.lastAcceptedOverride = currentOverride
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(commit: commit)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var commit: (String) -> Void
    /// Tracks the override value the field currently mirrors. Used by
    /// `updateNSView` to detect when an external rename has changed the
    /// catalog under us and the displayed text needs a quiet refresh.
    var lastAcceptedOverride: String?

    init(commit: @escaping (String) -> Void) {
      self.commit = commit
    }

    /// Fires on every keystroke. We forward the raw `stringValue` to the
    /// manager unchanged — trimming and the empty/canonical → `nil`
    /// collapse live in `renameProject`, so the field's text and the
    /// catalog's `displayName` stay in lockstep without us second-guessing
    /// what the user is mid-typing (a trim here would eat trailing spaces
    /// before the user finished a word).
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      let raw = field.stringValue
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      lastAcceptedOverride = trimmed.isEmpty ? nil : trimmed
      commit(raw)
    }
  }
}

/// Horizontal palette + custom-color trigger for the General section. Mirrors
/// the inline swatch row used by Tag Manager: a No-Color sentinel, the
/// seven Finder palette colors, then a multicolor disc that opens
/// NSColorPanel for arbitrary hex values.
///
/// Selection rules:
/// - Named / No-Color picks **don't** repaint the rightmost chip; it always
///   represents "Custom" as a slot, not the current selection.
/// - Clicking the rightmost chip opens the system color panel. The picked
///   color becomes the new `selection` AND the chip's fill — so the chip
///   acts as a recall button for the last hex the user chose.
/// - The remembered custom hex (`lastCustomHex`) is sticky across named
///   selections: switch to Red then back to Custom and you land on the
///   previous hue, not the default.
private struct ProjectColorSwatchRow: View {
  @Binding var selection: ProjectColor?

  /// Last hex chosen via the color panel. Seeded from `selection` if the
  /// project already carries a custom value when the row first appears, so
  /// the chip reflects state from a prior session.
  @State private var lastCustomHex: String?
  /// Holds the NSColorPanel callback target alive across panel-open and
  /// color-pick events. Cleared on disappear so the panel never calls into
  /// a freed observer.
  @State private var panelObserver: ColorPanelObserver?

  var body: some View {
    HStack(spacing: 8) {
      noColorChip
      ForEach(ProjectColor.namedCases, id: \.self) { color in
        namedChip(color)
      }
      customColorChip
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .onAppear { seedLastCustomFromSelection() }
    .onChange(of: selection) { _, _ in seedLastCustomFromSelection() }
    .onDisappear { detachColorPanelObserver() }
  }

  /// "No Color" sentinel — clears `selection` to nil so the Project falls
  /// back to the system accent.
  @ViewBuilder
  private var noColorChip: some View {
    ColorChip(
      isSelected: selection == nil,
      action: { selection = nil },
      accessibilityName: "No Color"
    ) {
      Image(systemName: "nosign")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func namedChip(_ color: ProjectColor) -> some View {
    ColorChip(
      isSelected: selection == color,
      action: { selection = color },
      accessibilityName: color.displayName
    ) {
      Circle()
        .fill(color.swiftUIColor)
        .frame(width: 16, height: 16)
        .overlay(
          Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
    }
  }

  /// Custom-color trigger. Renders either a multicolor disc (no custom
  /// hex yet) or a solid disc of the last picked hue. Click opens
  /// `NSColorPanel`; the picked color persists as `.custom(hex:)` and
  /// becomes the chip's visible fill.
  @ViewBuilder
  private var customColorChip: some View {
    let isSelected: Bool = {
      if case .custom = selection { return true }
      return false
    }()
    ColorChip(
      isSelected: isSelected,
      action: { openColorPanel() },
      accessibilityName: "Custom Color"
    ) {
      customCircleContent
    }
    .help("Custom Color…")
  }

  /// Fill content for the custom chip. Solid color when a custom hex is
  /// remembered; otherwise a smooth conic rainbow so the chip reads as
  /// "open the picker" rather than "currently set to something".
  @ViewBuilder
  private var customCircleContent: some View {
    if let hex = lastCustomHex, let color = ProjectColor.parseHex(hex) {
      Circle()
        .fill(color)
        .frame(width: 16, height: 16)
        .overlay(
          Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
    } else {
      Circle()
        .fill(
          AngularGradient(
            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
            center: .center
          )
        )
        .frame(width: 16, height: 16)
        .overlay(
          Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
        )
    }
  }

  // MARK: - NSColorPanel plumbing

  private func openColorPanel() {
    // Tear down any prior observer first — the panel target is shared global
    // state, and re-opening must not leave the previous binding wired up.
    if let existing = panelObserver {
      existing.unbind(from: NSColorPanel.shared)
    }
    let observer = ColorPanelObserver { nsColor in
      if let hex = ProjectColor.hex(from: nsColor) {
        lastCustomHex = hex
        selection = .custom(hex: hex)
      }
    }
    panelObserver = observer
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    if let hex = lastCustomHex, let nsColor = ProjectColor.nsColor(from: hex) {
      panel.color = nsColor
    }
    observer.bind(to: panel)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Avoid leaving a dangling target/action behind us — if the user closes
  /// the Settings window while the panel is still open, the panel would
  /// fire `colorDidChange:` into a deallocated observer otherwise.
  /// `NSColorPanel` doesn't expose its current target, so we conservatively
  /// detach whenever this row had set one. Setting `target` to `nil` is a
  /// no-op when something else has taken ownership in the meantime.
  private func detachColorPanelObserver() {
    guard let observer = panelObserver else { return }
    observer.unbind(from: NSColorPanel.shared)
    panelObserver = nil
  }

  private func seedLastCustomFromSelection() {
    if case .custom(let hex) = selection {
      lastCustomHex = hex
    }
  }
}

/// `NSColorPanel.setTarget(_:)` keeps an `unsafe_unretained` reference, so
/// the panel callback target must outlive the panel session. Held as the
/// `@State`-tracked `panelObserver` on `ProjectColorSwatchRow` and detached
/// on `onDisappear`.
///
/// The observer also self-deactivates as soon as the panel begins to close.
/// `NSColorPanel` fires a final `colorDidChange:` during its close animation
/// with the panel's current color reset to black; without the guard, that
/// stray callback would overwrite the just-picked hex with `#000000`. Hooking
/// `NSWindow.willCloseNotification` (the panel *is* a window) flips
/// `isActive` ahead of that final action so it's dropped on the floor.
@MainActor
private final class ColorPanelObserver: NSObject {
  let onChange: (NSColor) -> Void
  private var willCloseToken: NSObjectProtocol?
  private var isActive: Bool = true

  init(onChange: @escaping (NSColor) -> Void) {
    self.onChange = onChange
  }

  func bind(to panel: NSColorPanel) {
    isActive = true
    panel.setTarget(self)
    panel.setAction(#selector(colorDidChange(_:)))
    willCloseToken = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      // Posted on `.main` (see `queue:` above).
      MainActor.assumeIsolated { self?.isActive = false }
    }
  }

  func unbind(from panel: NSColorPanel) {
    isActive = false
    panel.setTarget(nil)
    panel.setAction(nil)
    if let token = willCloseToken {
      NotificationCenter.default.removeObserver(token)
      willCloseToken = nil
    }
  }

  @objc func colorDidChange(_ sender: NSColorPanel) {
    guard isActive else { return }
    onChange(sender.color)
  }
}

// MARK: - Lifecycle script section header style

/// Icon-led section header used by the worktree-lifecycle script editors.
private struct LifecycleSectionHeaderLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon
      configuration.title
    }
  }
}

extension LabelStyle where Self == LifecycleSectionHeaderLabelStyle {
  fileprivate static var lifecycleSectionHeader: LifecycleSectionHeaderLabelStyle { .init() }
}

// MARK: - Lifecycle inline editor

/// Tiny editor wrapper that commits the user's edit to the writer on each
/// change. Per-keystroke calls are safe: the writer routes through
/// `SettingsStore.scheduleSave`, which cancels and re-arms a debounced disk
/// write so a burst of keystrokes only triggers a single
/// `AtomicFileStore.write` once typing settles.
private struct LifecycleEditor: View {
  let initial: String
  let onCommit: (String) -> Void

  var body: some View {
    PlainCommandEditor(
      text: Binding(
        get: { initial },
        set: { newValue in
          if newValue != initial {
            onCommit(newValue)
          }
        }
      )
    )
    .frame(height: 90)
  }
}
