import SwiftUI

/// Picker for an `Optional<Value>` setting where `nil` represents "inherit
/// the global default". Renders the inherit row first with a label of the
/// form `"Global — \(inheritedLabel(inheritedValue))"`, followed by every
/// entry from `options`.
///
/// Centralising this visual prevents drift across the four override fields
/// in the General pane (editor / shell / merge strategy / post-merge
/// action) and the two textual override fields (worktree base ref) which
/// each take the same shape.
struct OptionalOverridePicker<Value: Hashable & Sendable>: View {
  let title: String
  @Binding var selection: Value?
  let inheritedValue: Value?
  let options: [Option]
  let inheritedLabel: (Value?) -> String

  /// Single picker entry. `label` is the user-visible string; `value`
  /// becomes the `.tag(.some(value))` payload.
  struct Option {
    let value: Value
    let label: String

    init(value: Value, label: String) {
      self.value = value
      self.label = label
    }
  }

  var body: some View {
    Picker(title, selection: $selection) {
      Text(Self.inheritRowText(inheritedLabel: inheritedLabel, inheritedValue: inheritedValue))
        .tag(Value?.none)
      ForEach(options, id: \.value) { option in
        Text(option.label).tag(Value?(option.value))
      }
    }
  }

  /// Pure helper — exposed for tests so we can assert label composition
  /// without rendering. The inherited label may itself be empty (no
  /// resolved global default); we still produce a sane string in that
  /// case rather than a dangling em-dash.
  nonisolated static func inheritRowText(
    inheritedLabel: (Value?) -> String,
    inheritedValue: Value?
  ) -> String {
    let resolved = inheritedLabel(inheritedValue)
    if resolved.isEmpty {
      return "Global"
    }
    return "Global — \(resolved)"
  }
}
