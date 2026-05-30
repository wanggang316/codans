import AppKit
import SwiftUI
import TouchCodeCore

/// Inline, spreadsheet-style editor for a Project's custom commands.
///
/// Replaces the old compact list + modal `ScriptEditorSheet`: every field is
/// edited in place. The layout is a clipped header + scrolling rows block,
/// with an add/remove bar and an inline hint underneath — the surrounding
/// grouped `Section` supplies the card chrome.
///
/// Each cell is an `InlineEditableCellButton` that paints a hover/active
/// border, so the whole row reads as a set of editable cells:
///   - **icon** → `ScriptIconPopover` (curated SF Symbol grid + free text).
///   - **name** → click flips the cell into an inline `TextField`.
///   - **command** → `ScriptCommandPopover` (execution target + script body).
///   - **shortcut** → the shared `HotkeyRecorderPopover`.
///
/// The view never touches the store: reads arrive as `scripts`, mutations
/// route back through the `onUpdate` / `onAdd` / `onDelete` closures so the
/// parent keeps single ownership of the TCA write path. Selection is lifted
/// to the parent so `onAdd` can select the freshly-created row.
struct ScriptCommandTable: View {
  let scripts: [ScriptDefinition]
  @Binding var selectedID: UUID?
  let onUpdate: (ScriptDefinition) -> Void
  let onAdd: () -> Void
  let onDelete: (UUID) -> Void
  /// Chord conflict check, excluding the row being edited.
  let validateChord: (ShortcutBinding, _ excluding: UUID) -> HotkeyRecorderPopover.ValidationResult

  private let iconColumnWidth: CGFloat = 48
  private let nameColumnWidth: CGFloat = 130
  private let shortcutColumnWidth: CGFloat = 100
  private let listHeight: CGFloat = 200

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(spacing: 0) {
        headerRow
        Divider()
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(scripts) { script in
              ScriptCommandRow(
                script: script,
                isSelected: selectedID == script.id,
                iconColumnWidth: iconColumnWidth,
                nameColumnWidth: nameColumnWidth,
                shortcutColumnWidth: shortcutColumnWidth,
                onSelect: { selectedID = script.id },
                onUpdate: onUpdate,
                validateChord: { binding in validateChord(binding, script.id) }
              )
              .id(script.id)
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
        }
        .frame(height: listHeight)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color(nsColor: .separatorColor))
      )

      bottomBar

      Text("Click cells to edit icon, name, command, and shortcut inline.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Header

  private var headerRow: some View {
    HStack(spacing: 8) {
      headerCell("", width: iconColumnWidth, alignment: .center)
      headerCell("Name", width: nameColumnWidth)
      headerCell("Command")
      headerCell("Shortcut", width: shortcutColumnWidth)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .font(.headline)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func headerCell(_ title: String, width: CGFloat? = nil, alignment: Alignment = .leading) -> some View {
    if let width {
      Text(title).frame(width: width, alignment: alignment)
    } else {
      Text(title).frame(maxWidth: .infinity, alignment: alignment)
    }
  }

  // MARK: - Add / remove bar

  private var bottomBar: some View {
    HStack(spacing: 8) {
      Button(action: onAdd) {
        ZStack {
          Image(systemName: "plus")
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel("Add command")
      }
      .buttonStyle(.plain)
      .help("Add command")

      Button {
        if let target = selectedID ?? scripts.last?.id {
          onDelete(target)
        }
      } label: {
        ZStack {
          Image(systemName: "minus")
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel("Remove selected command")
      }
      .buttonStyle(.plain)
      .disabled(scripts.isEmpty)
      .help("Remove selected command")

      Spacer(minLength: 0)

      Text("\(scripts.count) command\(scripts.count == 1 ? "" : "s")")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Row

private struct ScriptCommandRow: View {
  let script: ScriptDefinition
  let isSelected: Bool
  let iconColumnWidth: CGFloat
  let nameColumnWidth: CGFloat
  let shortcutColumnWidth: CGFloat
  let onSelect: () -> Void
  let onUpdate: (ScriptDefinition) -> Void
  let validateChord: (ShortcutBinding) -> HotkeyRecorderPopover.ValidationResult

  @State private var iconPopover = false
  @State private var commandPopover = false
  @State private var shortcutPopover = false
  @State private var isEditingName = false
  @FocusState private var nameFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      rowCell(width: iconColumnWidth, alignment: .center) { iconCell }
      rowCell(width: nameColumnWidth) { nameCell }
      rowCell { commandCell }
      rowCell(width: shortcutColumnWidth) { shortcutCell }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.35) : .clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .onTapGesture(perform: onSelect)
    .onChange(of: isSelected) { _, selected in
      if !selected { isEditingName = false }
    }
  }

  @ViewBuilder
  private func rowCell<Content: View>(
    width: CGFloat? = nil,
    alignment: Alignment = .leading,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if let width {
      content()
        .frame(width: width, alignment: alignment)
        .frame(maxHeight: .infinity, alignment: alignment)
    } else {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
  }

  // MARK: Icon

  private var iconCell: some View {
    InlineEditableCellButton(isActive: iconPopover, contentAlignment: .center) {
      onSelect()
      isEditingName = false
      commandPopover = false
      iconPopover.toggle()
    } label: {
      Image(systemName: script.resolvedSystemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16, alignment: .center)
        .accessibilityHidden(true)
    }
    .popover(isPresented: $iconPopover, arrowEdge: .bottom) {
      ScriptIconPopover(
        symbol: Binding(
          get: { script.systemImage ?? script.resolvedSystemImage },
          set: { onUpdate(script.applyingIcon($0)) }
        )
      )
    }
  }

  // MARK: Name

  @ViewBuilder
  private var nameCell: some View {
    if isEditingName {
      InlineEditableFieldContainer(isActive: true) {
        TextField(
          "",
          text: Binding(
            get: { script.name },
            set: {
              var updated = script
              updated.name = $0
              onUpdate(updated)
            }
          ),
          prompt: Text(script.kind.defaultName)
        )
        .textFieldStyle(.plain)
        .padding(.leading, -4)
        .focused($nameFocused)
        .onSubmit { isEditingName = false }
      }
      .onAppear { nameFocused = true }
      .onChange(of: nameFocused) { _, focused in
        if !focused { isEditingName = false }
      }
    } else {
      InlineEditableCellButton {
        onSelect()
        commandPopover = false
        iconPopover = false
        isEditingName = true
      } label: {
        Text(script.displayName)
          .lineLimit(1)
      }
    }
  }

  // MARK: Command

  private var commandCell: some View {
    InlineEditableCellButton(isActive: commandPopover) {
      onSelect()
      isEditingName = false
      iconPopover = false
      commandPopover.toggle()
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(ScriptTargetLabel.title(for: script.target))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(commandPreview)
          .lineLimit(1)
      }
    }
    .popover(isPresented: $commandPopover, arrowEdge: .bottom) {
      ScriptCommandPopover(script: script, onUpdate: onUpdate)
    }
    .help("New Tab opens a new tab. In Place writes into the focused pane. New Split splits it.")
  }

  private var commandPreview: String {
    let firstLine =
      script.command
      .split(separator: "\n", omittingEmptySubsequences: false)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return firstLine.isEmpty ? "Click to set command script" : firstLine
  }

  // MARK: Shortcut

  private var shortcutCell: some View {
    let hasChord: Bool = {
      if let binding = script.keyboardShortcut, binding.isEnabled, binding.keyCode != 0 {
        return true
      }
      return false
    }()
    let display: String = {
      if let binding = script.keyboardShortcut, binding.isEnabled, binding.keyCode != 0 {
        return ShortcutDisplay.chord(for: binding)
      }
      return "Unassigned"
    }()

    return InlineEditableCellButton(isActive: shortcutPopover) {
      onSelect()
      isEditingName = false
      shortcutPopover.toggle()
    } label: {
      Text(display)
        .font(.body.monospaced())
        .foregroundStyle(hasChord ? .primary : .secondary)
        .lineLimit(1)
    }
    .popover(isPresented: $shortcutPopover, arrowEdge: .bottom) {
      HotkeyRecorderPopover(
        title: "Shortcut for \(script.displayName)",
        validate: validateChord,
        onCommit: { binding in
          var updated = script
          updated.keyboardShortcut = binding
          onUpdate(updated)
        },
        onCancel: { shortcutPopover = false }
      )
    }
    .contextMenu {
      if hasChord {
        Button("Clear Shortcut") {
          var updated = script
          updated.keyboardShortcut = nil
          onUpdate(updated)
        }
      }
    }
    .help("Click to record a shortcut.")
  }
}

// MARK: - Target labels

/// View-layer display strings for `ScriptTarget`. Kept here rather than on
/// the domain enum so `TouchCodeCore` stays free of UI copy.
private enum ScriptTargetLabel {
  static func title(for target: ScriptTarget) -> String {
    switch target {
    case .newTab: return "New Tab"
    case .focused: return "In Place"
    case .split: return "New Split"
    }
  }

  static func footer(for target: ScriptTarget) -> String {
    switch target {
    case .newTab: return "Runs in a new terminal tab."
    case .focused: return "Sends input to the focused pane."
    case .split: return "Runs in a new split of the focused pane."
    }
  }
}

// MARK: - Icon popover

/// Curated SF Symbol grid plus a free-text field for any installed symbol,
/// with a shortcut to launch the SF Symbols app.
private struct ScriptIconPopover: View {
  @Binding var symbol: String
  @Environment(\.dismiss) private var dismiss

  private static let presets: [String] = [
    "terminal", "terminal.fill", "play.fill", "stop.fill",
    "hammer.fill", "shippingbox.fill", "doc.text.fill", "sparkles",
    "bolt.fill", "flame.fill", "wand.and.stars", "wrench.and.screwdriver.fill",
    "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "ladybug.fill",
    "clock.fill", "repeat", "arrow.clockwise", "folder.fill",
    "archivebox.fill", "paperplane.fill", "cloud.fill", "tray.and.arrow.down.fill",
    "tray.and.arrow.up.fill", "icloud.and.arrow.up.fill", "square.and.arrow.up.fill", "arrow.triangle.2.circlepath",
    "folder.badge.plus", "doc.badge.plus",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Icon")
        .font(.headline)
      Text("Pick from common symbols or enter any SF Symbol name available in your system.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("SF Symbol name", text: $symbol)
          .textFieldStyle(.roundedBorder)
        Button("Open SF Symbols", action: openSFSymbols)
      }

      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 10),
          spacing: 8
        ) {
          ForEach(Self.presets, id: \.self) { name in
            Button {
              symbol = name
              dismiss()
            } label: {
              Image(systemName: name)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(name)
          }
        }
        .padding(12)
      }
      .frame(maxHeight: 124)
    }
    .padding(12)
    .frame(width: 360)
  }

  /// Launch the SF Symbols app, falling back to the web reference.
  private func openSFSymbols() {
    let workspace = NSWorkspace.shared
    if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.SFSymbols") {
      workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
      return
    }
    if let url = URL(string: "https://developer.apple.com/sf-symbols/") {
      workspace.open(url)
    }
  }
}

// MARK: - Command popover

/// Execution target + script body editor. Edits commit live through
/// `onUpdate`; the shared `SettingsStore` debounce coalesces disk writes,
/// matching the lifecycle editors elsewhere in this pane.
private struct ScriptCommandPopover: View {
  let script: ScriptDefinition
  let onUpdate: (ScriptDefinition) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Command")
        .font(.headline)
      Text("Choose where this command runs and edit the script used by this repository custom command.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Execution", selection: targetBinding) {
        Text("New Tab").tag(ScriptTarget.newTab)
        Text("In Place").tag(ScriptTarget.focused)
        Text("New Split").tag(ScriptTarget.split)
      }
      .pickerStyle(.segmented)

      if script.target == .split {
        Picker("Split Direction", selection: directionBinding) {
          Text("Right").tag(ScriptSplitDirection.right)
          Text("Down").tag(ScriptSplitDirection.down)
          Text("Left").tag(ScriptSplitDirection.left)
          Text("Up").tag(ScriptSplitDirection.up)
        }
        .pickerStyle(.menu)
        .help("Direction to split the focused pane.")
      }

      PlainCommandEditor(text: commandBinding)
        .frame(height: 140)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(nsColor: .separatorColor))
        )

      Text(ScriptTargetLabel.footer(for: script.target))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if script.target != .focused {
        Toggle("Close when finished", isOn: closeBinding)
          .toggleStyle(.checkbox)
          .help("Closes the spawned tab or split once the command's process exits.")
      }
    }
    .padding(12)
    .frame(width: 420)
  }

  // MARK: Bindings

  private var commandBinding: Binding<String> {
    Binding(
      get: { script.command },
      set: {
        var updated = script
        updated.command = $0
        onUpdate(updated)
      }
    )
  }

  /// Switching target resets `onFinished` to `.none` — the per-target valid
  /// set differs, so carrying a stale value would silently encode an invalid
  /// combo until `resolvedOnFinished` strips it at dispatch.
  private var targetBinding: Binding<ScriptTarget> {
    Binding(
      get: { script.target },
      set: {
        var updated = script
        updated.target = $0
        updated.onFinished = .none
        onUpdate(updated)
      }
    )
  }

  private var directionBinding: Binding<ScriptSplitDirection> {
    Binding(
      get: { script.direction },
      set: {
        var updated = script
        updated.direction = $0
        onUpdate(updated)
      }
    )
  }

  /// Maps the single "Close when finished" checkbox onto the target-specific
  /// `ScriptOnFinished` case (`.closeTab` for a tab, `.closePane` for a split).
  private var closeBinding: Binding<Bool> {
    Binding(
      get: {
        switch script.target {
        case .newTab: return script.onFinished == .closeTab
        case .split: return script.onFinished == .closePane
        case .focused: return false
        }
      },
      set: { isOn in
        var updated = script
        switch script.target {
        case .newTab: updated.onFinished = isOn ? .closeTab : .none
        case .split: updated.onFinished = isOn ? .closePane : .none
        case .focused: updated.onFinished = .none
        }
        onUpdate(updated)
      }
    )
  }
}

// MARK: - Inline cell primitives

/// Cell-sized button that paints a rounded border on hover and a coloured
/// border while its editor is active, so each table cell reads as a
/// distinct click target without permanent chrome.
private struct InlineEditableCellButton<Label: View>: View {
  let isActive: Bool
  let activeColor: Color
  let contentAlignment: Alignment
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  @State private var isHovering = false

  init(
    isActive: Bool = false,
    activeColor: Color = .accentColor,
    contentAlignment: Alignment = .leading,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.contentAlignment = contentAlignment
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(action: action) {
      label()
        .frame(maxWidth: .infinity, alignment: contentAlignment)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: contentAlignment)
    .onHover { isHovering = $0 }
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(borderColor, lineWidth: borderWidth)
    )
  }

  private var borderColor: Color {
    if isActive { return activeColor }
    if isHovering { return Color(nsColor: .tertiaryLabelColor) }
    return .clear
  }

  private var borderWidth: CGFloat {
    (isActive || isHovering) ? 1 : 0
  }
}

/// Sibling of `InlineEditableCellButton` for cells that host a live control
/// (the inline name `TextField`) rather than a tap action.
private struct InlineEditableFieldContainer<Content: View>: View {
  let isActive: Bool
  let activeColor: Color
  @ViewBuilder let content: () -> Content

  @State private var isHovering = false

  init(
    isActive: Bool = false,
    activeColor: Color = .accentColor,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.content = content
  }

  var body: some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onHover { isHovering = $0 }
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(borderColor, lineWidth: borderWidth)
      )
  }

  private var borderColor: Color {
    if isActive { return activeColor }
    if isHovering { return Color(nsColor: .tertiaryLabelColor) }
    return .clear
  }

  private var borderWidth: CGFloat {
    (isActive || isHovering) ? 1 : 0
  }
}

// MARK: - Icon edit helper

extension ScriptDefinition {
  /// Returns a copy with `systemImage` set to `symbol`. A predefined-kind
  /// script is flipped to `.custom` (preserving its visible name) so the
  /// override actually renders — the resolver only honours overrides for
  /// `.custom`, and the inline table treats every command as customizable.
  fileprivate func applyingIcon(_ symbol: String) -> ScriptDefinition {
    var copy = self
    if copy.kind != .custom {
      if copy.name.isEmpty { copy.name = copy.kind.defaultName }
      copy.kind = .custom
    }
    let trimmed = symbol.trimmingCharacters(in: .whitespaces)
    copy.systemImage = trimmed.isEmpty ? nil : trimmed
    return copy
  }
}
