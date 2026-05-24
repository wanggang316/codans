import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// General pane — Appearance + global "Default editor" picker.
///
/// Appearance writes directly through `SettingsStore.setAppearance(_:)` (injected via the
/// environment-held store); the value is read back by `AppAppearanceView` wrapped around
/// every scene to drive both SwiftUI's `.preferredColorScheme` and the AppKit
/// `NSApp.appearance` poke. No TCA round-trip because appearance doesn't participate in
/// any other reducer state.
///
/// Editor picker contract: shared visual style with every other Open-in dropdown across
/// the app — a flat priority-ordered list of installed editors (no Automatic sentinel,
/// no grouping/dividers), each row showing `icon + displayName` via `EditorPickerRow`.
/// Priority walk when `globalDefault` is nil is still honoured downstream in
/// `EditorFeature.resolveDefault`; the picker simply does not surface the nil state as
/// a selectable choice.
///
/// Refresh model: the view dispatches `.refreshRequested` on appear so the service's
/// `describe()` cache is flushed before re-fetch. Editors installed while touch-code was
/// running therefore surface the first time Settings is opened (design R4).
struct SettingsGeneralView: View {
  @Bindable var store: StoreOf<EditorFeature>
  let settingsStore: SettingsStore
  /// Invoked when the Appearance footer's "Terminal" link is tapped. Routes
  /// selection over to the Terminal pane so the user can pick light/dark
  /// terminal themes that the Appearance choice will then switch between.
  let onJumpToTerminal: () -> Void

  private var selectionBinding: Binding<EditorID?> {
    Binding(
      get: { store.globalDefault },
      set: { store.send(.setGlobalDefault($0)) }
    )
  }

  private var appearanceBinding: Binding<AppearancePreference> {
    Binding(
      get: { settingsStore.settings.general.appearance },
      set: { settingsStore.setAppearance($0) }
    )
  }

  /// Settings → General → Default Git Viewer binding. `nil` means "use the in-app
  /// Git Viewer overlay"; any other id names an installed git client from
  /// `EditorRegistry.gitClientPriority` that should open instead when the user
  /// invokes the Git Viewer chord (⌘⌥G) or menu item.
  private var gitViewerBinding: Binding<EditorID?> {
    Binding(
      get: { settingsStore.settings.general.defaultGitViewerID },
      set: { settingsStore.setDefaultGitViewerID($0) }
    )
  }

  private var agentsViewAutoOpenBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.general.agentsViewAutoOpen },
      set: { settingsStore.setAgentsViewAutoOpen($0) }
    )
  }

  /// Installed git clients surfaced under "Default Git Viewer". Sourced from the
  /// editor feature's `describe()` cache so only installed apps show up; the
  /// `gitClientPriority` filter walks `EditorRegistry`'s git-tool group in its
  /// canonical priority order.
  private var installedGitClients: [EditorDescriptor] {
    let byID = Dictionary(uniqueKeysWithValues: store.descriptors.map { ($0.id, $0) })
    return EditorRegistry.gitClientPriority.compactMap { byID[$0] }
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Appearance") {
          AppearancePicker(selection: appearanceBinding)
        }
      } footer: {
        Text(
          .init(
            "To change the terminal theme, open the [Terminal](touchcode://settings/terminal) "
              + "pane. When both light and dark terminal themes are set there, they switch "
              + "in sync with this Appearance choice."
          )
        )
        .environment(
          \.openURL,
          OpenURLAction { _ in
            onJumpToTerminal()
            return .handled
          }
        )
      }

      Section {
        Picker("Default editor", selection: selectionBinding) {
          editorPickerContent
        }
        .pickerStyle(.menu)
      } footer: {
        Text(
          "Used when opening a directory. Falls back to Finder if the chosen editor "
            + "is uninstalled later."
        )
      }

      Section {
        Picker("Default Git Viewer", selection: gitViewerBinding) {
          gitViewerPickerContent
        }
        .pickerStyle(.menu)
      } footer: {
        Text(
          "Drives the Git Viewer chord (⌘⌥G). Built-in shows the in-app overlay; "
            + "any other choice opens the worktree in that git client. Falls back to "
            + "the built-in viewer if the chosen client is uninstalled later."
        )
      }

      Section {
        Toggle("Auto-open Agents View", isOn: agentsViewAutoOpenBinding)
      } footer: {
        Text("The sidebar panel opens automatically when an agent is running.")
      }
    }
    .formStyle(.grouped)
    .task { store.send(.refreshRequested) }
    .onAppear { store.send(.onAppear) }
  }

  /// Editor picker body — grouped by `EditorPickerRow.sortedGroups` so editors,
  /// terminals, git clients, and the shell pseudo-editor render with section
  /// dividers between them. The shared `row(for:)` builder keeps every Open-in
  /// dropdown's row visuals identical.
  @ViewBuilder
  private var editorPickerContent: some View {
    ForEach(Array(EditorPickerRow.sortedGroups(store.descriptors).enumerated()), id: \.offset) { _, group in
      Section {
        ForEach(group, id: \.id) { descriptor in
          EditorPickerRow.row(for: descriptor)
            .tag(EditorID?(descriptor.id))
        }
      }
    }
  }

  /// Default Git Viewer picker body. Leads with the built-in sentinel (tag nil),
  /// followed by every installed git client in priority order.
  @ViewBuilder
  private var gitViewerPickerContent: some View {
    Label {
      Text("Built-in")
    } icon: {
      Image(systemName: "doc.text.magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .labelStyle(.titleAndIcon)
    .tag(EditorID?(nil))

    if !installedGitClients.isEmpty {
      Section {
        ForEach(installedGitClients, id: \.id) { descriptor in
          EditorPickerRow.row(for: descriptor)
            .tag(EditorID?(descriptor.id))
        }
      }
    }
  }
}

#if DEBUG
  #Preview("SettingsGeneralView") {
    SettingsGeneralView(
      store: Store(initialState: EditorFeature.State()) { EditorFeature() },
      settingsStore: SettingsStore(
        fileURL: FileManager.default.temporaryDirectory.appending(component: "\(UUID()).json"),
        debounceWindow: .seconds(3600)
      ),
      onJumpToTerminal: {}
    )
    .frame(width: 520, height: 320)
  }
#endif
