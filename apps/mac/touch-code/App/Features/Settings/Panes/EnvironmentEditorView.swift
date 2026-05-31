import AppKit
import SwiftUI
import TouchCodeCore

/// Reusable key/value editor for `[String: String]` environment-variable
/// maps. The General pane wraps this in a grouped `Section` so each row
/// renders with native Form chrome (inset card, hairline separators) and
/// each commit routes through `SettingsWriter.setProjectEnvVar(pid, key,
/// value)`; M6's per-hook env editor reuses the same component with a
/// hooks-aware writer.
///
/// Layout mirrors the System-Settings idiom: every row is a
/// `LabeledContent` with a two-line label (monospaced KEY over a secondary
/// subtitle). `builtins` pins read-only rows for the variables touch-code
/// injects automatically — their subtitle documents the meaning (the
/// concrete value resolves per-pane at spawn time) and a trailing button
/// copies the key. Editable rows show the current value as the subtitle,
/// open an Add/Edit sheet on tap, and carry a trailing remove button.
///
/// Add and Edit both push a modal sheet (`EnvVarEditorSheet`) rather than
/// editing inline, matching the Scripts pane's editor. The sheet enforces
/// the validation rules (Risk R3 from the design doc):
///   - KEY must match POSIX env-var: `^[A-Za-z_][A-Za-z0-9_]*$`.
///   - KEY must not collide with a reserved built-in or an existing key.
///   - VALUE must not contain `\n` or `\r` — the on-disk JSON is shell-
///     sourced by hook runners; embedded newlines break the contract.
///
/// Editable rows render alphabetically by key on each pass; insertion
/// order is not preserved (Swift dictionaries don't guarantee it anyway).
struct EnvironmentEditorView: View {
  @Binding var envVars: [String: String]
  /// App-provided, read-only variables pinned above the editable rows.
  /// Empty for callers (like the hooks editor) that have no built-ins.
  var builtins: [BuiltinEnvVar] = []
  /// Per-row commit hook. `value == nil` means delete. Wrapping views use
  /// it to fan out into `SettingsWriter.setProjectEnvVar` etc. without
  /// this view knowing about ProjectIDs.
  let onChange: (_ key: String, _ value: String?) -> Void

  /// Drives the Add/Edit sheet. Non-nil = sheet visible against this draft.
  @State private var editing: EnvVarEdit?

  /// Each statement below is a sibling row in the host's `Section`, so the
  /// grouped Form paints native separators and insets between them.
  var body: some View {
    ForEach(builtins, id: \.self) { builtinRow($0) }

    ForEach(sortedKeys, id: \.self) { key in
      existingRow(key: key)
    }

    addRow
  }

  /// Editable keys, with any reserved built-in name filtered out so a
  /// stale on-disk entry can't render twice (once locked, once editable).
  private var sortedKeys: [String] {
    envVars.keys
      .filter { !BuiltinEnvVar.reservedKeys.contains($0) }
      .sorted()
  }

  // MARK: - Built-in rows

  /// Read-only row for an app-provided variable: monospaced key over a
  /// secondary description, with a trailing button that copies the key to
  /// the pasteboard. The value is resolved per-pane at spawn time, so the
  /// row documents the meaning rather than showing a concrete value.
  @ViewBuilder
  private func builtinRow(_ builtin: BuiltinEnvVar) -> some View {
    LabeledContent {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(builtin.key, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
          .accessibilityLabel("Copy \(builtin.key)")
      }
      .buttonStyle(.borderless)
      .help("Copy variable name")
    } label: {
      Text(builtin.key).monospaced()
      Text(builtin.summary)
    }
  }

  // MARK: - Existing rows

  /// Editable variable: monospaced key over its current value. Tapping the
  /// row opens the edit sheet; the trailing button removes it.
  @ViewBuilder
  private func existingRow(key: String) -> some View {
    let value = envVars[key] ?? ""
    LabeledContent {
      Button {
        onChange(key, nil)
      } label: {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .help("Remove \(key)")
      .accessibilityLabel("Remove \(key)")
    } label: {
      Text(key).monospaced()
      Text(value.isEmpty ? "—" : value)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      editing = EnvVarEdit(key: key, value: value, isNew: false)
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Edit value")
  }

  // MARK: - Add row

  /// Trailing action row that opens the Add sheet. Mirrors the Scripts
  /// pane's "Add" affordance (text label + `plus`, borderless) and the
  /// macOS "Add…" rows in System Settings. The Add/Edit sheet is anchored
  /// here since this row is always present.
  private var addRow: some View {
    Button {
      editing = EnvVarEdit(key: "", value: "", isNew: true)
    } label: {
      Label("Add Variable", systemImage: "plus")
    }
    .buttonStyle(.borderless)
    .sheet(item: $editing) { edit in
      EnvVarEditorSheet(
        key: edit.key,
        value: edit.value,
        isNew: edit.isNew,
        existing: envVars,
        onSave: { newKey, newValue in
          onChange(newKey, newValue)
          editing = nil
        },
        onCancel: { editing = nil }
      )
    }
  }
}

/// In-flight Add/Edit draft. `isNew` distinguishes "creating" (KEY is
/// editable and validated) from "editing" (KEY is fixed; only the value
/// changes). Identity is the key, with a stable sentinel for the single
/// new-variable draft so `.sheet(item:)` presents exactly once.
private struct EnvVarEdit: Identifiable {
  var key: String
  var value: String
  var isNew: Bool

  var id: String { isNew ? "\u{0}new" : key }
}

/// Modal sheet for adding or editing one environment variable. Body is a
/// System-Settings-style grouped `Form`; edits accumulate in local state
/// and commit through `onSave` only when valid. On edit the KEY is
/// read-only — renaming is a remove-then-add — so the value is the only
/// mutable field.
private struct EnvVarEditorSheet: View {
  let isNew: Bool
  /// Current map, used to flag a duplicate KEY when adding.
  let existing: [String: String]
  let onSave: (_ key: String, _ value: String) -> Void
  let onCancel: () -> Void

  @State private var key: String
  @State private var value: String

  init(
    key: String,
    value: String,
    isNew: Bool,
    existing: [String: String],
    onSave: @escaping (_ key: String, _ value: String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.isNew = isNew
    self.existing = existing
    self.onSave = onSave
    self.onCancel = onCancel
    self._key = State(initialValue: key)
    self._value = State(initialValue: value)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Name") {
            TextField("EXAMPLE_NAME", text: $key)
              .textFieldStyle(.roundedBorder)
              .font(.system(.body, design: .monospaced))
              .frame(minWidth: 220)
              .disabled(!isNew)
          }
          LabeledContent("Value") {
            TextField("value", text: $value)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 220)
          }
        } footer: {
          if let error {
            Text(error).foregroundStyle(.red)
          } else if isNew {
            Text("Letters, digits, and underscores; can't start with a digit.")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(isNew ? "Add Variable" : "Edit Variable")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(key, value)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
        }
      }
    }
    .frame(minWidth: 440, idealWidth: 500, minHeight: 220)
  }

  /// Inline validation message, or nil when the draft is committable. On
  /// edit only the value rule applies (the KEY field is disabled and
  /// already valid); on add the full KEY + value rules run.
  private var error: String? {
    if isNew {
      return EnvVarValidator.errorFor(key: key, value: value, existing: existing)
    }
    return EnvVarValidator.valueHasNewline(value) ? "Value cannot contain newlines" : nil
  }

  private var canSave: Bool {
    !key.isEmpty && error == nil
  }
}

/// Pure validator — kept as a free enum so tests can hit the rules
/// without spinning up SwiftUI state. `nonisolated` because the rules
/// are static and pure; SwiftUI's main-actor inference would otherwise
/// pin them to the MainActor and force every test to be `@MainActor`.
nonisolated enum EnvVarValidator {
  /// Returns the user-visible error string when `(key, value)` cannot be
  /// committed against `existing`. Returns nil for a valid pair (and for
  /// the empty-KEY initial state, which is "incomplete" rather than
  /// "invalid"; the commit path checks `!key.isEmpty` separately).
  static func errorFor(
    key: String,
    value: String,
    existing: [String: String]
  ) -> String? {
    if !key.isEmpty, !keyIsValidPOSIX(key) {
      return "Invalid key"
    }
    if !key.isEmpty, BuiltinEnvVar.reservedKeys.contains(key) {
      return "Reserved by touch-code"
    }
    if !key.isEmpty, existing[key] != nil {
      return "Key already exists"
    }
    if valueHasNewline(value) {
      return "Value cannot contain newlines"
    }
    return nil
  }

  /// `true` iff `key` matches `^[A-Za-z_][A-Za-z0-9_]*$`. POSIX env-var
  /// keys are strictly ASCII; Foundation's `CharacterSet.letters` includes
  /// Unicode letters and would over-accept, so we use raw scalar ranges.
  static func keyIsValidPOSIX(_ key: String) -> Bool {
    guard !key.isEmpty else { return false }
    for (index, scalar) in key.unicodeScalars.enumerated() {
      let isAsciiAlpha =
        (scalar.value >= 0x41 && scalar.value <= 0x5A)
        || (scalar.value >= 0x61 && scalar.value <= 0x7A)
      let isAsciiDigit = scalar.value >= 0x30 && scalar.value <= 0x39
      let isUnderscore = scalar == "_"
      if index == 0 {
        // First scalar: letter or underscore only — digits are not allowed
        // as the first character.
        if !(isAsciiAlpha || isUnderscore) { return false }
      } else {
        if !(isAsciiAlpha || isAsciiDigit || isUnderscore) { return false }
      }
    }
    return true
  }

  static func valueHasNewline(_ value: String) -> Bool {
    value.contains("\n") || value.contains("\r")
  }
}
