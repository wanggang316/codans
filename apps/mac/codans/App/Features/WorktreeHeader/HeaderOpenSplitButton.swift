import ComposableArchitecture
import SwiftUI
import CodansCore

/// Native toolbar split button: primary action opens the resolved
/// default editor; the chevron half lists every installed editor. Uses
/// SwiftUI's `Menu(content:label:primaryAction:)` so macOS provides the
/// system split-button chrome, hover state, and chevron. Resolution +
/// delegate routing flow through `WorktreeHeaderFeature`, keeping the
/// open side-effect on `RootFeature`.
struct HeaderOpenSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Bindable var editorStore: StoreOf<EditorFeature>
  let projectID: ProjectID
  let worktreePath: String
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore

  var body: some View {
    // Server (remote) worktrees have a remote path a local editor / Finder
    // can't open, so the toolbar Open button is suppressed for them (matching
    // the sidebar context-menu guard).
    if isRemoteProject {
      EmptyView()
    } else {
      openButton
    }
  }

  private var isRemoteProject: Bool {
    hierarchyManager.catalog.projects
      .first(where: { $0.id == projectID })?.isRemote ?? false
  }

  @ViewBuilder
  private var openButton: some View {
    Menu {
      openInMenu
    } label: {
      // Chord hint rides on the primary half (icon + label) only — applying it on the
      // outer HStack used to push the chord text to the trailing edge of the label
      // group, where it visually merged with the system-rendered chevron and read as
      // "the dropdown button's chord". Anchoring on `primaryIcon` keeps the chord
      // tight against the icon, well left of the chevron, so it clearly belongs to
      // the primary "Open in <Editor>" action.
      HStack(spacing: 4) {
        primaryIcon
          .commandKeyHint(.openInEditor)
        Text(primaryLabel)
          .lineLimit(1)
      }
    } primaryAction: {
      store.send(
        .openDefaultEditorTapped(
          worktreePath: worktreePath,
          projectID: projectID
        ))
    }
    .accessibilityLabel(primaryDescription)
    .helpWithShortcut(primaryDescription, .openInEditor)
    .task { editorStore.send(.onAppear) }
  }

  @ViewBuilder
  private var primaryIcon: some View {
    switch resolvedDefault {
    case .editor(let descriptor):
      AppIconImage(
        bundleIdentifier: descriptor.bundleIdentifier,
        fallbackSystemName: "arrow.up.right.square"
      )
    case .finder:
      AppIconImage(
        bundleIdentifier: "com.apple.finder",
        fallbackSystemName: "folder"
      )
    }
  }

  /// Visible button label. Drops the "Open in " prefix so the trailing
  /// toolbar capsules stay compact; the icon already conveys intent.
  private var primaryLabel: String {
    switch resolvedDefault {
    case .editor(let descriptor): return descriptor.displayName
    case .finder: return "Finder"
    }
  }

  /// Verbose form used for accessibility + help tooltip — VoiceOver and
  /// the hover tooltip still benefit from the explicit verb.
  private var primaryDescription: String {
    switch resolvedDefault {
    case .editor(let descriptor): return "Open in \(descriptor.displayName)"
    case .finder: return "Open in Finder"
    }
  }

  private var resolvedDefault: EditorFeature.ResolvedDefault {
    EditorFeature.resolveDefault(
      projectOverride: projectOverrideID,
      globalDefault: editorStore.state.globalDefault,
      descriptors: editorStore.state.descriptors
    )
  }

  private var projectOverrideID: EditorID? {
    // v3 reads per-Project editor override from settings.json.projects[pid].
    settingsStore.settings.projects[projectID]?.defaultEditor
  }

  @ViewBuilder
  private var openInMenu: some View {
    // `EditorService.describe()` already filters to installed entries, so every
    // descriptor is launch-ready. `EditorPickerRow.sortedGroups` groups the
    // priority-ordered list by category — AppKit renders one `Divider()` between
    // adjacent groups, mirroring the section separators in Settings → General /
    // Repository. `row(for:)` keeps the icon + displayName row visuals in sync
    // with every other Open-in dropdown.
    let groups = EditorPickerRow.sortedGroups(editorStore.state.descriptors)
    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
      if index > 0 { Divider() }
      ForEach(group, id: \.id) { descriptor in
        Button {
          // Single action: parent resolves the live worktree path from
          // `state.selection`, persists the pick as the per-Project default,
          // then opens. Avoids the SwiftUI Menu / NSMenuItem stale-closure
          // trap where `worktreePath` captured at view-render time would
          // route the open to the originally-selected worktree (often the
          // project root) after the user switched worktrees.
          store.send(.pickEditorFromMenuTapped(descriptor.id))
        } label: {
          EditorPickerRow.row(for: descriptor)
        }
        .help(descriptor.displayName)
      }
    }
  }
}
