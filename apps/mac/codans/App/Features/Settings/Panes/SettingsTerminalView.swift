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
        fontSection(snapshot: snapshot)
        cursorStyleSection(snapshot: snapshot)
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
      ThemePickerButton(
        title: "Light",
        options: lightOptions,
        previews: snapshot.themePreviews,
        selection: snapshot.lightTheme,
        isDisabled: controlsDisabled,
        onPick: { store.send(.lightThemeSelected($0)) }
      )
      ThemePickerButton(
        title: "Dark",
        options: darkOptions,
        previews: snapshot.themePreviews,
        selection: snapshot.darkTheme,
        isDisabled: controlsDisabled,
        onPick: { store.send(.darkThemeSelected($0)) }
      )
    } header: {
      Text("Theme")
    } footer: {
      Text(
        "Codans reads and writes your Ghostty config, so changes here stay in sync "
          + "with Ghostty itself."
      )
    }
  }

  // MARK: - Font

  /// Common terminal point sizes offered in the size picker; the user's current
  /// size is prepended when it falls outside this set.
  private static let fontSizeChoices: [Double] = [
    9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24,
  ]

  private func fontSection(snapshot: GhosttyTerminalSettings) -> some View {
    let familyBinding = Binding<String?>(
      get: { snapshot.fontFamily },
      set: { store.send(.fontFamilySelected($0)) }
    )
    let sizeBinding = Binding<Double?>(
      get: { snapshot.fontSize },
      set: { store.send(.fontSizeSelected($0)) }
    )
    let families = prepending(snapshot.fontFamily, to: snapshot.availableFontFamilies)
    let sizes = prepending(snapshot.fontSize, to: Self.fontSizeChoices)
    return Section {
      Picker("Font", selection: familyBinding) {
        Text("Default").tag(String?.none)
        ForEach(families, id: \.self) { family in
          fontFamilyLabel(family, isMonospaced: snapshot.monospacedFontFamilies.contains(family))
            .tag(String?.some(family))
        }
      }
      .disabled(controlsDisabled)
      Picker("Size", selection: sizeBinding) {
        Text("Default").tag(Double?.none)
        ForEach(sizes, id: \.self) { size in
          Text(sizeLabel(size)).tag(Double?.some(size))
        }
      }
      .disabled(controlsDisabled)
    } header: {
      Text("Font")
    } footer: {
      Text("\"Default\" leaves the font to your Ghostty config.")
    }
  }

  private func sizeLabel(_ size: Double) -> String {
    let number = size == size.rounded() ? String(Int(size)) : String(size)
    return "\(number) pt"
  }

  /// Picker row for a font family. Monospaced families get a leading `</>`
  /// code glyph so the terminal-appropriate fonts stand out in the full list.
  /// `Label` carries the family name as its title, so the symbol stays
  /// accessible without a separate accessibility label.
  @ViewBuilder
  private func fontFamilyLabel(_ family: String, isMonospaced: Bool) -> some View {
    if isMonospaced {
      Label(family, systemImage: "chevron.left.forwardslash.chevron.right")
    } else {
      Text(family)
    }
  }

  /// Prepend `current` to `list` when it's a value missing from the catalog, so
  /// the picker shows the on-disk selection verbatim instead of collapsing to
  /// "Default".
  private func prepending<T: Equatable>(_ current: T?, to list: [T]) -> [T] {
    guard let current, !list.contains(current) else { return list }
    return [current] + list
  }

  // MARK: - Cursor style

  private func cursorStyleSection(snapshot: GhosttyTerminalSettings) -> some View {
    // Bind directly to the snapshot's cursor style; on change we dispatch the
    // pick, which rewrites the managed config block and reloads the snapshot.
    // `nil` is the "Default" tag — Codans stops managing `cursor-style` and
    // Ghostty's own default (block) applies.
    let selection = Binding<GhosttyCursorStyle?>(
      get: { snapshot.cursorStyle },
      set: { store.send(.cursorStyleSelected($0)) }
    )
    return Section {
      Picker("Cursor Style", selection: selection) {
        Text("Default").tag(GhosttyCursorStyle?.none)
        ForEach(GhosttyCursorStyle.allCases, id: \.self) { style in
          Text(style.displayName).tag(GhosttyCursorStyle?.some(style))
        }
      }
      .disabled(controlsDisabled)
    } header: {
      Text("Cursor")
    } footer: {
      Text("\"Default\" leaves the cursor shape to your Ghostty config.")
    }
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
