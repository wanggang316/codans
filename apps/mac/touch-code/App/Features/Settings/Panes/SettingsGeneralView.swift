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
  /// not see a count they cannot influence. `@Observable` so the count
  /// re-renders when runtime bring-ups upsert rows or when the user
  /// clicks Forget-all.
  let sessionCoordinator: SessionCoordinator?
  /// Forget-all-sessions handler injected from the app layer so the
  /// view does not need to import the zmx socket-kill helper. Receives
  /// the coordinator so the action can iterate rows + dispatch the
  /// platform-side teardown (kill each daemon, unlink each socket,
  /// clear the catalog). Nil in headless previews.
  let onForgetAllSessions: (() -> Void)?

  /// Confirmation alert state for the destructive Forget-all action.
  /// SwiftUI's `.alert(_:isPresented:)` modifier is the simplest way to
  /// gate a destructive operation in the Settings form.
  @State private var showForgetConfirmation: Bool = false

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

  private var agentsViewAutoSortBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.general.agentsViewAutoSort },
      set: { settingsStore.setAgentsViewAutoSort($0) }
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

      if let coordinator = sessionCoordinator {
        let count = coordinator.catalog.sessions.count
        Section {
          LabeledContent("Sessions saved for next launch") {
            Text("\(count)")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Button("Forget all sessions…", role: .destructive) {
            showForgetConfirmation = true
          }
          .disabled(count == 0 || onForgetAllSessions == nil)
        } footer: {
          Text(
            "Counts the rows in sessions.json that the next launch would try "
              + "to reattach. Forget all kills the recorded daemons, removes their "
              + "sockets, and empties the catalog — the current panes detach from "
              + "their daemons and become unrestorable."
          )
        }
        .alert("Forget \(count) saved session\(count == 1 ? "" : "s")?",
               isPresented: $showForgetConfirmation) {
          Button("Forget", role: .destructive) {
            onForgetAllSessions?()
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "Each recorded daemon will be terminated and its socket removed. "
              + "Any pane currently attached to one of these daemons will lose "
              + "its scrollback and respawn a fresh shell on the next launch."
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
        Toggle(isOn: agentsViewAutoSortBinding) {
          Text("Auto-sort")
          Text(
            "Reorders agents by status — needs input, finished, working, "
              + "then idle. Off keeps them in the order they appeared."
          )
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
      onJumpToTerminal: {},
      sessionCoordinator: nil,
      onForgetAllSessions: nil
    )
    .frame(width: 520, height: 320)
  }
#endif
