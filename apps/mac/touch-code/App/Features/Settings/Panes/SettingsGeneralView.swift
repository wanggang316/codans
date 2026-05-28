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
  /// Persisted-session catalog, threaded from `bootstrapSessionStack`.
  /// `nil` when the launch acquired no catalog lock (no-resume mode) —
  /// the corresponding section is hidden in that case so the user does
  /// not see a count they cannot influence.
  let sessionCoordinator: SessionCoordinator?

  /// Snapshot of the catalog row count read once when the pane appears
  /// and recomputed after a "Forget all" action. We avoid an `@Observable`
  /// dependency on `SessionCoordinator` because the catalog mutates
  /// from runtime paths (spawn / reattach) that have no business waking
  /// the settings window — the user opening settings is the only
  /// trigger we need to reflect.
  @State private var resumableSessionCount: Int = 0

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

  /// "Confirm before quitting" picker binding. Reads `settings.general.quitConfirmation`;
  /// writes route through the dedicated setter so the debounced atomic write fires.
  private var quitConfirmationBinding: Binding<QuitConfirmation> {
    Binding(
      get: { settingsStore.settings.general.quitConfirmation },
      set: { settingsStore.setQuitConfirmation($0) }
    )
  }

  /// "On quit" action picker binding. Drives both the no-dialog branch (applied directly)
  /// and the default-focused button when the dialog IS shown.
  private var quitActionBinding: Binding<QuitAction> {
    Binding(
      get: { settingsStore.settings.general.quitAction },
      set: { settingsStore.setQuitAction($0) }
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

  private var agentsViewDisplayModeBinding: Binding<AgentsViewDisplayMode> {
    Binding(
      get: { settingsStore.settings.general.agentsViewDisplayMode },
      set: { settingsStore.setAgentsViewDisplayMode($0) }
    )
  }

  private var crashReportsEnabledBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.general.crashReportsEnabled },
      set: { settingsStore.setCrashReportsEnabled($0) }
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
        Picker("Confirm before quitting", selection: quitConfirmationBinding) {
          Text("Auto (only when panes are running)").tag(QuitConfirmation.auto)
          Text("Always").tag(QuitConfirmation.always)
          Text("Never").tag(QuitConfirmation.never)
        }
        Picker("On quit", selection: quitActionBinding) {
          Text("Keep session running").tag(QuitAction.keepRunning)
          Text("Snapshot and exit").tag(QuitAction.snapshot)
        }
      } footer: {
        Text(
          "Keep session running lets long-running commands survive the quit; "
            + "Snapshot saves the screen state and exits."
        )
      }

      if sessionCoordinator != nil {
        Section {
          LabeledContent("Sessions saved for next launch") {
            Text("\(resumableSessionCount)")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Button("Forget all sessions", role: .destructive) {
            forgetAllSessions()
          }
          .disabled(resumableSessionCount == 0)
        } footer: {
          Text(
            "Counts the rows in sessions.json that the next launch would "
              + "try to reattach. Forget all clears the catalog; any daemon "
              + "still running is left for the launch-time reaper to clean up."
          )
        }
      }

      Section {
        Picker("Default editor", selection: selectionBinding) {
          editorPickerContent
        }
        .pickerStyle(.menu)
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

      Section("Agents View") {
        Toggle(isOn: agentsViewAutoOpenBinding) {
          Text("Auto-open")
          Text("Opens the sidebar panel automatically when an agent is running.")
        }
        Picker("Display Mode", selection: agentsViewDisplayModeBinding) {
          Text("Normal").tag(AgentsViewDisplayMode.normal)
          Text("Compact").tag(AgentsViewDisplayMode.compact)
        }
        .pickerStyle(.menu)
      }

      Section {
        Toggle("Send crash reports", isOn: crashReportsEnabledBinding)
      } header: {
        Text("Diagnostics")
      } footer: {
        Text(
          "Helps fix problems by uploading anonymous crash details when the app "
            + "stops unexpectedly. No file contents, terminal output, or personal "
            + "information are sent. A change takes effect after the next launch."
        )
      }
    }
    .formStyle(.grouped)
    .task { store.send(.refreshRequested) }
    .onAppear {
      store.send(.onAppear)
      refreshResumableCount()
    }
  }

  /// Read the catalog count once. Called on pane appear so a Forget-all
  /// from a previous appearance is reflected next time the user opens
  /// settings, and the count tracks runtime spawns recorded since launch.
  private func refreshResumableCount() {
    resumableSessionCount = sessionCoordinator?.catalog.sessions.count ?? 0
  }

  /// Clear the on-disk catalog. Daemons currently running are not killed
  /// — they survive in the OS process tree until their own exit. The
  /// launch-time FS-orphan reaper picks them up if the user quits before
  /// they shut down on their own.
  private func forgetAllSessions() {
    guard let coordinator = sessionCoordinator else { return }
    do {
      try coordinator.replace(SessionCatalog(sessions: [:]))
      resumableSessionCount = 0
    } catch {
      // Persist failures are rare (disk full, sandbox revoke) and would
      // already be logged by the coordinator. The UI keeps the displayed
      // count so the user sees the operation did not take effect.
      refreshResumableCount()
    }
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
      onJumpToTerminal: {},
      sessionCoordinator: nil
    )
    .frame(width: 520, height: 320)
  }
#endif
