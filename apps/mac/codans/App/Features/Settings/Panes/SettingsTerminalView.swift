import AppKit
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// Detail pane for Settings → Terminal. Presents two side-by-side theme pickers
/// (Light / Dark) backed by the Ghostty theme catalog; writes flow through
/// `SettingsTerminalFeature` → `GhosttyTerminalSettingsClient` → `GhosttyConfigFile`,
/// which atomically rewrites the managed region of `~/.config/ghostty/config` and
/// fires a notification that the live `GhosttyRuntime` picks up — so selections
/// take effect in running terminals without an app restart.
struct SettingsTerminalView: View {
  @Bindable var store: StoreOf<SettingsTerminalFeature>

  // Deliberately excludes `isApplying`: an apply is a fast, cancellable write,
  // and disabling controls mid-apply makes the theme rows dim then restore —
  // the "flicker" seen when switching font/cursor. Rapid re-picks are already
  // coalesced by the reducer's cancel-in-flight.
  private var controlsDisabled: Bool {
    store.isLoading || store.snapshot == nil
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
    }
  }

  // MARK: - Font

  /// Common terminal point sizes offered in the size picker; the user's current
  /// size is prepended when it falls outside this set.
  private static let fontSizeChoices: [Double] = [
    9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 24,
  ]

  private func fontSection(snapshot: GhosttyTerminalSettings) -> some View {
    let sizeBinding = Binding<Double?>(
      get: { snapshot.fontSize },
      set: { store.send(.fontSizeSelected($0)) }
    )
    let families = prepending(snapshot.fontFamily, to: snapshot.availableFontFamilies)
    let sizes = prepending(snapshot.fontSize, to: Self.fontSizeChoices)
    return Section {
      FontPickerButton(
        title: "Font Family",
        families: families,
        monospaced: snapshot.monospacedFontFamilies,
        selection: snapshot.fontFamily,
        isDisabled: controlsDisabled,
        onPick: { store.send(.fontFamilySelected($0)) }
      )
      Picker("Font Size", selection: sizeBinding) {
        Text("Default").tag(Double?.none)
        ForEach(sizes, id: \.self) { size in
          Text(sizeLabel(size)).tag(Double?.some(size))
        }
      }
      .disabled(controlsDisabled)
    } header: {
      Text("Font")
    } footer: {
      Text("Recommended: a monospaced font — marked with the </> badge — for the cleanest terminal rendering.")
    }
  }

  private func sizeLabel(_ size: Double) -> String {
    let number = size == size.rounded() ? String(Int(size)) : String(size)
    return "\(number) pt"
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
    }
  }

  // MARK: - Config file path

  private func configFileSection(path: String) -> some View {
    Section {
      HStack(spacing: 8) {
        Text(path)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button {
          openConfigFile(path)
        } label: {
          Label("Open in text editor", systemImage: "square.and.pencil")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Open in default text editor")
      }
    } header: {
      Text("Config File")
    } footer: {
      Text(
        "Codans reads and writes your Ghostty config, so changes here stay in sync "
          + "with Ghostty itself."
      )
    }
  }

  /// Open the config file in the user's default plain-text editor. The file has
  /// no extension, so we route through the plain-text handler rather than
  /// `open(_:)` (which can fail to find an association for an extensionless
  /// file). When the file doesn't exist yet — nothing has been saved — reveal
  /// the directory instead.
  private func openConfigFile(_ path: String) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      NSWorkspace.shared.open(url.deletingLastPathComponent())
      return
    }
    if let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText) {
      NSWorkspace.shared.open(
        [url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()
      )
    } else {
      NSWorkspace.shared.open(url)
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
