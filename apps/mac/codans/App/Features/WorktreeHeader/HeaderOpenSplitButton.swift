import CodansCore
import ComposableArchitecture
import SwiftUI

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
    // Server (remote) worktrees open through an editor's SSH remoting CLI —
    // the menu narrows to editors that can express the host (see
    // `RemoteEditorOpen`), and disappears entirely when none is installed.
    if let host = projectRemoteHost {
      if let primary = remoteResolvedDefault(host: host) {
        remoteOpenButton(host: host, primary: primary)
      }
    } else {
      openButton
    }
  }

  private var projectRemoteHost: RemoteHost? {
    hierarchyManager.catalog.projects
      .first(where: { $0.id == projectID })?.remoteHost
  }

  @ViewBuilder
  private var openButton: some View {
    Menu {
      openInMenu
    } label: {
      // Icon only; the editor name lives in the tooltip and accessibility
      // label. The chord hint hangs off the icon itself so it sits right
      // after the glyph, well left of the system chevron, and reads as the
      // primary "Open in <Editor>" action's chord rather than the dropdown's.
      primaryIcon
        .commandKeyHint(.openInEditor)
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

  // MARK: - Remote (Server-project) variant

  /// The editor a remote open will land on, mirroring the service cascade so
  /// the label matches the primary tap. nil = no SSH-capable editor installed.
  private func remoteResolvedDefault(host: RemoteHost) -> EditorDescriptor? {
    EditorFeature.resolveRemoteDefault(
      projectOverride: projectOverrideID,
      globalDefault: editorStore.state.globalDefault,
      descriptors: editorStore.state.descriptors,
      host: host
    )
  }

  @ViewBuilder
  private func remoteOpenButton(host: RemoteHost, primary: EditorDescriptor) -> some View {
    Menu {
      remoteOpenInMenu(host: host)
    } label: {
      AppIconImage(
        bundleIdentifier: primary.bundleIdentifier,
        fallbackSystemName: "arrow.up.right.square"
      )
      .commandKeyHint(.openInEditor)
    } primaryAction: {
      store.send(
        .openDefaultEditorTapped(
          worktreePath: worktreePath,
          projectID: projectID
        ))
    }
    .accessibilityLabel("Open in \(primary.displayName) over SSH")
    .helpWithShortcut("Open in \(primary.displayName) over SSH", .openInEditor)
    .task { editorStore.send(.onAppear) }
  }

  /// Remote dropdown: only editors with an SSH remoting CLI. A row that
  /// cannot express this host (VS Code family on a non-default port) renders
  /// disabled with the reason as its tooltip.
  @ViewBuilder
  private func remoteOpenInMenu(host: RemoteHost) -> some View {
    let capable = editorStore.state.descriptors.filter {
      RemoteEditorOpen.supportsRemote($0.id)
    }
    ForEach(capable, id: \.id) { descriptor in
      let reason = RemoteEditorOpen.disabledReason(
        editorID: descriptor.id, host: host, displayName: descriptor.displayName
      )
      Button {
        store.send(.pickEditorFromMenuTapped(descriptor.id))
      } label: {
        EditorPickerRow.row(for: descriptor)
      }
      .disabled(reason != nil)
      .help(reason ?? descriptor.displayName)
    }
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

  /// Accessibility + help tooltip text. The button itself is icon-only, so
  /// this is where VoiceOver and the hover tooltip learn the verb and the
  /// editor's name.
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
