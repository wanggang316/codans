import SwiftUI
import TouchCodeCore

/// Reusable key/value editor for `[String: String]` environment-variable
/// maps. The General pane wraps this in a grouped `Section` so each row
/// renders with native Form chrome (inset card, hairline separators) and
/// each commit routes through `SettingsWriter.setProjectEnvVar(pid, key,
/// value)`; M6's per-hook env editor reuses the same component with a
/// hooks-aware writer.
///
/// `builtins` pins read-only rows above the editable ones for the
/// variables touch-code injects automatically (e.g. the worktree/root
/// paths in the Project General pane). They are documentation: the
/// concrete value is resolved per-pane at spawn time, so the row shows the
/// variable's meaning rather than a value, and the keys are reserved (see
/// `EnvVarValidator`). Callers that have no built-ins pass an empty array.
///
/// Validation rules (Risk R3 from the design doc):
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

  @State private var draft: Draft?

  /// Each statement below is a sibling row in the host's `Section`, so the
  /// grouped Form paints native separators and insets between them.
  var body: some View {
    ForEach(builtins, id: \.self) { builtinRow($0) }

    ForEach(sortedKeys, id: \.self) { key in
      existingRow(key: key)
    }

    if let draft {
      draftRow(draft)
    } else {
      addRow
    }
  }

  /// Editable keys, with any reserved built-in name filtered out so a
  /// stale on-disk entry can't render twice (once locked, once editable).
  private var sortedKeys: [String] {
    envVars.keys
      .filter { !BuiltinEnvVar.reservedKeys.contains($0) }
      .sorted()
  }

  // MARK: - Built-in rows

  /// Read-only row for an app-provided variable. `LabeledContent` gives
  /// the canonical macOS left-label / right-value layout; the trailing
  /// lock signals the row is managed by touch-code and can't be edited.
  @ViewBuilder
  private func builtinRow(_ builtin: BuiltinEnvVar) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        Text(builtin.summary)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        Image(systemName: "lock.fill")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityLabel("Read-only")
      }
    } label: {
      Text(builtin.key)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
    }
    .help("Provided automatically by touch-code")
  }

  // MARK: - Existing rows

  @ViewBuilder
  private func existingRow(key: String) -> some View {
    let valueBinding = Binding<String>(
      get: { envVars[key] ?? "" },
      set: { newValue in
        if EnvVarValidator.valueHasNewline(newValue) {
          // Reject silently here — the textfield UI keeps the typed
          // characters but the commit-on-blur path filters on the same
          // rule so nothing reaches disk. Inline error rendered below.
          return
        }
        onChange(key, newValue)
      }
    )

    HStack(spacing: 8) {
      Text(key)
        .font(.system(.body, design: .monospaced))
        .frame(width: 180, alignment: .leading)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      TextField("value", text: valueBinding)
        .textFieldStyle(.roundedBorder)
      Button {
        onChange(key, nil)
      } label: {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Remove \(key)")
      .accessibilityLabel("Remove \(key)")
    }
  }

  // MARK: - Add row

  /// Trailing action row that starts a draft. Mirrors the Scripts pane's
  /// "Add" affordance (text label + `plus`, borderless) and the macOS
  /// "Add…" rows in System Settings.
  private var addRow: some View {
    Button {
      if draft == nil {
        draft = Draft()
      }
    } label: {
      Label("Add Variable", systemImage: "plus")
    }
    .buttonStyle(.borderless)
  }

  // MARK: - Draft row

  @ViewBuilder
  private func draftRow(_ current: Draft) -> some View {
    let keyBinding = Binding<String>(
      get: { current.key },
      set: { newValue in
        var next = current
        next.key = newValue
        next.recomputeError(existing: envVars)
        draft = next
      }
    )
    let valueBinding = Binding<String>(
      get: { current.value },
      set: { newValue in
        var next = current
        next.value = newValue
        next.recomputeError(existing: envVars)
        draft = next
      }
    )

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField("KEY", text: keyBinding)
          .textFieldStyle(.roundedBorder)
          .frame(width: 180)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(current.error == nil ? Color.clear : Color.red, lineWidth: 1)
          )
        TextField("value", text: valueBinding)
          .textFieldStyle(.roundedBorder)
        Button {
          commitDraft()
        } label: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(canCommitDraft ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!canCommitDraft)
        .help("Add variable")
        .accessibilityLabel("Commit new variable")
        Button {
          draft = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Cancel")
        .accessibilityLabel("Discard new variable")
      }
      if let error = current.error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var canCommitDraft: Bool {
    guard let current = draft else { return false }
    return current.error == nil && !current.key.isEmpty
  }

  private func commitDraft() {
    guard let current = draft, current.error == nil, !current.key.isEmpty else {
      return
    }
    onChange(current.key, current.value)
    draft = nil
  }

  // MARK: - Draft state

  /// In-flight unsaved row. Held in `@State` so a half-typed KEY does not
  /// fan out to the parent's onChange until validation passes and the
  /// user commits.
  struct Draft: Equatable {
    var key: String = ""
    var value: String = ""
    var error: String?

    mutating func recomputeError(existing: [String: String]) {
      error = EnvVarValidator.errorFor(key: key, value: value, existing: existing)
    }
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
