import CodansCore
import ComposableArchitecture
import SwiftUI

/// Toolbar split button: primary action opens the resolved default editor;
/// the chevron half lists every installed editor. Drawn by
/// `OpenInSplitButton`, the same AppKit control as SwiftUI's toolbar
/// `Menu(primaryAction:)`, so that the chord can take the icon's place while
/// ⌘ is held. Resolution + delegate routing flow through
/// `WorktreeHeaderFeature`, keeping the open side-effect on `RootFeature`.
struct HeaderOpenSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  @Bindable var editorStore: StoreOf<EditorFeature>
  let projectID: ProjectID
  let worktreePath: String
  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

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

  private var openButton: some View {
    // Icon only; the editor name lives in the tooltip and accessibility label.
    OpenInSplitButton(
      icon: primaryImage,
      chordHint: chordHint,
      toolTip: ShortcutDisplay.tooltip(primaryDescription, for: .openInEditor, in: resolvedShortcuts),
      accessibilityLabel: primaryDescription,
      onPrimary: openDefaultEditor,
      makeMenu: { openInMenu }
    )
    .task { editorStore.send(.onAppear) }
  }

  /// The Open In chord while ⌘ is held. It takes the icon's place.
  private var chordHint: String? {
    commandKeyObserver.isCommandHeld ? ShortcutDisplay.chord(for: .openInEditor, in: resolvedShortcuts) : nil
  }

  private func openDefaultEditor() {
    store.send(
      .openDefaultEditorTapped(
        worktreePath: worktreePath,
        projectID: projectID
      ))
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

  private func remoteOpenButton(host: RemoteHost, primary: EditorDescriptor) -> some View {
    let description = "Open in \(primary.displayName) over SSH"
    return OpenInSplitButton(
      icon: Self.appIcon(bundleIdentifier: primary.bundleIdentifier, fallbackSystemName: "arrow.up.right.square"),
      chordHint: chordHint,
      toolTip: ShortcutDisplay.tooltip(description, for: .openInEditor, in: resolvedShortcuts),
      accessibilityLabel: description,
      onPrimary: openDefaultEditor,
      makeMenu: { [remoteOpenInMenu(host: host)] }
    )
    .task { editorStore.send(.onAppear) }
  }

  /// Remote dropdown: only editors with an SSH remoting CLI. A row that
  /// cannot express this host (VS Code family on a non-default port) renders
  /// disabled with the reason as its tooltip.
  private func remoteOpenInMenu(host: RemoteHost) -> [OpenInMenuEntry] {
    editorStore.state.descriptors
      .filter { RemoteEditorOpen.supportsRemote($0.id) }
      .map { descriptor in
        let reason = RemoteEditorOpen.disabledReason(
          editorID: descriptor.id, host: host, displayName: descriptor.displayName
        )
        return OpenInMenuEntry(
          title: descriptor.displayName,
          image: EditorPickerRow.menuImage(for: descriptor),
          toolTip: reason ?? descriptor.displayName,
          isEnabled: reason == nil,
          action: { store.send(.pickEditorFromMenuTapped(descriptor.id)) }
        )
      }
  }

  private var primaryImage: NSImage? {
    switch resolvedDefault {
    case .editor(let descriptor):
      Self.appIcon(bundleIdentifier: descriptor.bundleIdentifier, fallbackSystemName: "arrow.up.right.square")
    case .finder:
      Self.appIcon(bundleIdentifier: "com.apple.finder", fallbackSystemName: "folder")
    }
  }

  /// The app's icon at the toolbar glyph size, or the fallback symbol when the
  /// app is not installed (see `AppIconImage`).
  private static func appIcon(bundleIdentifier: String, fallbackSystemName: String) -> NSImage? {
    if let url = EditorAppIcons.appURL(bundleIdentifier: bundleIdentifier) {
      return EditorAppIcons.resizedIcon(atPath: url.path, side: 16)
    }
    return NSImage(systemSymbolName: fallbackSystemName, accessibilityDescription: nil)
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

  private var openInMenu: [[OpenInMenuEntry]] {
    // `EditorService.describe()` already filters to installed entries, so every
    // descriptor is launch-ready. `EditorPickerRow.sortedGroups` groups the
    // priority-ordered list by category, with a separator between groups.
    EditorPickerRow.sortedGroups(editorStore.state.descriptors).map { group in
      group.map { descriptor in
        OpenInMenuEntry(
          title: descriptor.displayName,
          image: EditorPickerRow.menuImage(for: descriptor),
          toolTip: descriptor.displayName,
          // Single action: parent resolves the live worktree path from
          // `state.selection`, persists the pick as the per-Project default,
          // then opens, so a pick never routes to a worktree path captured
          // before the user switched worktrees.
          action: { store.send(.pickEditorFromMenuTapped(descriptor.id)) }
        )
      }
    }
  }
}
