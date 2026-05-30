import AppKit
import SwiftUI
import TouchCodeCore

/// Inline, spreadsheet-style editor for a Project's custom commands.
///
/// Replaces the old compact list + modal `ScriptEditorSheet`: every field
/// is edited in place. A row exposes four click targets —
///   - **icon**: opens `ScriptIconPopover` (curated SF Symbol grid + free
///     text name + Open SF Symbols).
///   - **name**: an always-editable plain `TextField`.
///   - **command**: opens `ScriptCommandPopover` (execution target +
///     multi-line script + close-on-finish).
///   - **shortcut**: opens the shared `HotkeyRecorderPopover`.
///
/// The view is intentionally dumb: it never touches the store directly.
/// Reads come in as `scripts`; every mutation routes back out through the
/// `onUpdate` / `onAdd` / `onDelete` / `onReorder` closures so the parent
/// keeps single ownership of the TCA write path. Selection is lifted to the
/// parent (`selectedID`) so `onAdd` can select the freshly-created row.
struct ScriptCommandTable: View {
  let scripts: [ScriptDefinition]
  @Binding var selectedID: UUID?
  let onUpdate: (ScriptDefinition) -> Void
  let onAdd: () -> Void
  let onDelete: (UUID) -> Void
  /// Reorder: move `source` to sit where `target` currently is.
  let onReorder: (_ source: UUID, _ target: UUID) -> Void
  /// Chord conflict check, excluding the row being edited.
  let validateChord: (ShortcutBinding, _ excluding: UUID) -> HotkeyRecorderPopover.ValidationResult

  /// Leading icon column. Matched between header and rows so titles align.
  private let iconColumnWidth: CGFloat = 44
  /// Trailing shortcut column. Fixed so chord chips line up across rows.
  private let shortcutColumnWidth: CGFloat = 132

  var body: some View {
    VStack(spacing: 0) {
      headerRow
      Divider()
      rowsArea
      Divider()
      bottomBar
    }
  }

  // MARK: - Header

  private var headerRow: some View {
    HStack(spacing: 10) {
      Color.clear.frame(width: iconColumnWidth, height: 1)
      columnTitle("Name")
        .frame(minWidth: 80, idealWidth: 140, maxWidth: 200, alignment: .leading)
      columnTitle("Command")
        .frame(maxWidth: .infinity, alignment: .leading)
      columnTitle("Shortcut")
        .frame(width: shortcutColumnWidth, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func columnTitle(_ text: String) -> some View {
    Text(text)
      .font(.headline)
      .foregroundStyle(.secondary)
  }

  // MARK: - Rows

  @ViewBuilder
  private var rowsArea: some View {
    if scripts.isEmpty {
      Text("No commands yet — click + to create one.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        .padding(.horizontal, 14)
    } else {
      VStack(spacing: 4) {
        ForEach(scripts) { script in
          ScriptCommandRow(
            script: script,
            isSelected: selectedID == script.id,
            iconColumnWidth: iconColumnWidth,
            shortcutColumnWidth: shortcutColumnWidth,
            onSelect: { selectedID = script.id },
            onUpdate: onUpdate,
            validateChord: { binding in validateChord(binding, script.id) }
          )
          .draggable(script.id.uuidString)
          .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let source = UUID(uuidString: first),
              source != script.id
            else { return false }
            onReorder(source, script.id)
            return true
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 180, alignment: .top)
    }
  }

  // MARK: - Bottom bar

  private var bottomBar: some View {
    HStack(spacing: 2) {
      Button(action: onAdd) {
        Image(systemName: "plus")
          .frame(width: 24, height: 20)
          .contentShape(Rectangle())
          .accessibilityLabel("Add command")
      }
      .buttonStyle(.borderless)
      .help("Add command")

      Button {
        if let selectedID { onDelete(selectedID) }
      } label: {
        Image(systemName: "minus")
          .frame(width: 24, height: 20)
          .contentShape(Rectangle())
          .accessibilityLabel("Remove selected command")
      }
      .buttonStyle(.borderless)
      .disabled(selectedID == nil)
      .help("Remove selected command")

      Spacer()

      Text("\(scripts.count) command\(scripts.count == 1 ? "" : "s")")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

// MARK: - Row

private struct ScriptCommandRow: View {
  let script: ScriptDefinition
  let isSelected: Bool
  let iconColumnWidth: CGFloat
  let shortcutColumnWidth: CGFloat
  let onSelect: () -> Void
  let onUpdate: (ScriptDefinition) -> Void
  let validateChord: (ShortcutBinding) -> HotkeyRecorderPopover.ValidationResult

  @State private var iconPopover = false
  @State private var commandPopover = false
  @State private var shortcutPopover = false
  @State private var shortcutHovering = false

  var body: some View {
    HStack(spacing: 10) {
      iconCell
        .frame(width: iconColumnWidth, alignment: .center)

      nameCell
        .frame(minWidth: 80, idealWidth: 140, maxWidth: 200, alignment: .leading)

      commandCell
        .frame(maxWidth: .infinity, alignment: .leading)

      shortcutCell
        .frame(width: shortcutColumnWidth, alignment: .trailing)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
  }

  // MARK: Icon

  private var iconCell: some View {
    Button {
      onSelect()
      iconPopover = true
    } label: {
      Image(systemName: script.resolvedSystemImage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary)
        .frame(width: 28, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary)
        )
        .accessibilityLabel("Command icon")
    }
    .buttonStyle(.plain)
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

  private var nameCell: some View {
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
    .font(.body)
  }

  // MARK: Command

  private var commandCell: some View {
    Button {
      onSelect()
      commandPopover = true
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(ScriptTargetLabel.title(for: script.target))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(commandPreview)
          .font(.body)
          .foregroundStyle(script.command.isEmpty ? .secondary : .primary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $commandPopover, arrowEdge: .bottom) {
      ScriptCommandPopover(
        script: script,
        onUpdate: onUpdate
      )
    }
  }

  private var commandPreview: String {
    let firstLine = script.command
      .split(whereSeparator: \.isNewline)
      .first
      .map { String($0).trimmingCharacters(in: .whitespaces) }
    if let firstLine, !firstLine.isEmpty {
      return firstLine
    }
    return "Click to set command script"
  }

  // MARK: Shortcut

  private var shortcutCell: some View {
    Button {
      onSelect()
      shortcutPopover = true
    } label: {
      shortcutLabel
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .trailing) {
      if hasShortcut, shortcutHovering {
        Button {
          var updated = script
          updated.keyboardShortcut = nil
          onUpdate(updated)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Clear shortcut")
        }
        .buttonStyle(.plain)
        .help("Clear shortcut")
      }
    }
    .onHover { shortcutHovering = $0 }
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
  }

  private var hasShortcut: Bool {
    if let binding = script.keyboardShortcut, binding.isEnabled, binding.keyCode != 0 {
      return true
    }
    return false
  }

  @ViewBuilder
  private var shortcutLabel: some View {
    if let binding = script.keyboardShortcut, binding.isEnabled, binding.keyCode != 0 {
      Text(ShortcutDisplay.chord(for: binding))
        .font(.callout.monospaced())
        .foregroundStyle(.primary)
    } else {
      Text("Unassigned")
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
    }
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
    case .focused: return "Runs in the focused pane."
    case .split: return "Splits the focused pane."
    }
  }
}

// MARK: - Icon popover

/// Compact icon picker: a curated SF Symbol grid plus a free-text field for
/// any symbol installed on the system, with a shortcut to launch SF Symbols.
private struct ScriptIconPopover: View {
  @Binding var symbol: String

  private static let curated: [String] = [
    "terminal", "terminal.fill", "play.fill", "stop.fill",
    "hammer.fill", "shippingbox.fill", "doc.text.fill", "sparkles",
    "bolt.fill", "flame.fill", "wand.and.stars", "wrench.and.screwdriver.fill",
    "checkmark.circle.fill", "xmark.circle.fill", "exclamationmark.triangle.fill", "ant.fill",
    "clock.fill", "arrow.triangle.2.circlepath", "arrow.clockwise", "folder.fill",
    "archivebox.fill", "paperplane.fill", "cloud.fill", "tray.and.arrow.down.fill",
    "tray.and.arrow.up.fill", "icloud.and.arrow.up.fill", "square.and.arrow.up.fill", "arrow.triangle.branch",
    "folder.badge.plus", "doc.badge.plus", "gearshape.fill", "magnifyingglass",
  ]

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 10)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Icon")
        .font(.headline)

      Text("Pick from common symbols or enter any SF Symbol name available in your system.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        TextField("SF Symbol name", text: $symbol)
          .textFieldStyle(.roundedBorder)
        Button("Open SF Symbols", action: openSFSymbols)
      }

      LazyVGrid(columns: columns, spacing: 8) {
        ForEach(Self.curated, id: \.self) { name in
          cell(name)
        }
      }
    }
    .padding(16)
    .frame(width: 460)
  }

  @ViewBuilder
  private func cell(_ name: String) -> some View {
    let isSelected = name == symbol
    Button {
      symbol = name
    } label: {
      Image(systemName: name)
        .font(.body)
        .foregroundStyle(.primary)
        .frame(width: 30, height: 26)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        )
        .accessibilityLabel(name)
    }
    .buttonStyle(.plain)
    .help(name)
  }

  /// Best-effort launch of the SF Symbols app. No-op when it isn't installed.
  private func openSFSymbols() {
    let workspace = NSWorkspace.shared
    if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.SFSymbols") {
      workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
    VStack(alignment: .leading, spacing: 12) {
      Text("Command")
        .font(.headline)

      Text("Choose where this command runs and edit the script used by this repository custom command.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        Text("Execution")
          .foregroundStyle(.secondary)
        Picker("Execution", selection: targetBinding) {
          Text("New Tab").tag(ScriptTarget.newTab)
          Text("In Place").tag(ScriptTarget.focused)
          Text("New Split").tag(ScriptTarget.split)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      if script.target == .split {
        HStack(spacing: 12) {
          Text("Direction")
            .foregroundStyle(.secondary)
          Picker("Direction", selection: directionBinding) {
            Text("Right").tag(ScriptSplitDirection.right)
            Text("Down").tag(ScriptSplitDirection.down)
            Text("Left").tag(ScriptSplitDirection.left)
            Text("Up").tag(ScriptSplitDirection.up)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }

      PlainCommandEditor(text: commandBinding)
        .frame(height: 120)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )

      Text(ScriptTargetLabel.footer(for: script.target))
        .font(.caption)
        .foregroundStyle(.secondary)

      if script.target != .focused {
        Toggle("Close when finished", isOn: closeBinding)
          .toggleStyle(.checkbox)
      }
    }
    .padding(16)
    .frame(width: 460)
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
