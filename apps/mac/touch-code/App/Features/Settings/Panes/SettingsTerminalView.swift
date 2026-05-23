import ComposableArchitecture
import SwiftUI

/// Detail pane for Settings → Terminal. Presents two side-by-side theme pickers
/// (Light / Dark) backed by the Ghostty theme catalog; writes flow through
/// `SettingsTerminalFeature` → `GhosttyTerminalSettingsClient` → `GhosttyConfigFile`,
/// which atomically rewrites the managed region of `~/.config/ghostty/config` and
/// fires a notification that the live `GhosttyRuntime` picks up — so selections
/// take effect in running terminals without an app restart.
struct SettingsTerminalView: View {
  @Bindable var store: StoreOf<SettingsTerminalFeature>

  private var controlsDisabled: Bool {
    store.isLoading || store.isApplying || store.snapshot == nil
  }

  var body: some View {
    Form {
      if let snapshot = store.snapshot {
        themePickersSection(snapshot: snapshot)
        configFileSection(path: snapshot.configPath)
      } else if store.isLoading {
        Section {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading Ghostty config…")
              .foregroundStyle(.secondary)
          }
        }
      }
      messagesSection
    }
    .formStyle(.grouped)
    .task { store.send(.onAppear) }
  }

  // MARK: - Theme pickers

  private func themePickersSection(snapshot: GhosttyTerminalSettings) -> some View {
    let lightOptions = themeOptions(
      list: snapshot.availableLightThemes,
      selected: snapshot.lightTheme
    )
    let darkOptions = themeOptions(
      list: snapshot.availableDarkThemes,
      selected: snapshot.darkTheme
    )
    return Section {
      themePickerRow(
        title: "Light",
        options: lightOptions,
        selection: snapshot.lightTheme
      ) { store.send(.lightThemeSelected($0)) }
      themePickerRow(
        title: "Dark",
        options: darkOptions,
        selection: snapshot.darkTheme
      ) { store.send(.darkThemeSelected($0)) }
    } header: {
      Text("Theme")
    } footer: {
      Text(
        "TouchCode reads and writes your Ghostty config, so changes here stay in sync "
          + "with Ghostty itself."
      )
    }
  }

  private func themePickerRow(
    title: String,
    options: [String],
    selection: String?,
    onPick: @escaping (String?) -> Void
  ) -> some View {
    let binding = Binding<String?>(
      get: { selection },
      set: { onPick($0) }
    )
    return Picker(title, selection: binding) {
      if selection == nil {
        Text("Select Theme").tag(String?.none)
      }
      ForEach(options, id: \.self) { theme in
        Text(theme).tag(String?.some(theme))
      }
    }
    .pickerStyle(.menu)
    .disabled(controlsDisabled)
  }

  // MARK: - Config file path

  private func configFileSection(path: String) -> some View {
    Section("Config File") {
      Text(path)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Messages

  @ViewBuilder
  private var messagesSection: some View {
    if let warning = store.warningMessage {
      Section {
        banner(text: warning, color: .orange)
      }
    }
    if let error = store.errorMessage {
      Section {
        banner(text: error, color: .red)
      }
    }
  }

  private func banner(text: String, color: Color) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(color)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(color.opacity(0.1), in: .rect(cornerRadius: 6))
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Picker option building

  /// If the currently selected theme is not in the catalog (renamed / removed), prepend
  /// it so the picker still shows the current value verbatim rather than quietly
  /// collapsing to nil on open.
  private func themeOptions(list: [String], selected: String?) -> [String] {
    guard let selected, !selected.isEmpty, !list.contains(selected) else { return list }
    return [selected] + list
  }
}
