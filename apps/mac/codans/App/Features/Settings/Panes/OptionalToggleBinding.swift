import SwiftUI

/// Three-state Picker for an `Optional<Bool>` setting where `nil` means
/// "inherit the global default" and `true` / `false` are explicit
/// overrides. Used by the Worktree Section's
/// `copyIgnoredOnWorktreeCreate` / `copyUntrackedOnWorktreeCreate` rows —
/// a plain `Toggle` has only two states and cannot express the inherit
/// case.
///
/// `inheritedValue` is the resolved global default the inherit-row label
/// surfaces ("Global — yes" / "no"). When the project has no global
/// default for the field today (M4 ships before a global Bool default
/// exists for these toggles), callers pass the on-disk fallback the rest
/// of the app uses (typically `false`).
struct TriStateOverrideToggle: View {
  let title: String
  @Binding var selection: Bool?
  let inheritedValue: Bool

  enum TriState: Hashable {
    case inherit
    case yes
    case no
  }

  private var triBinding: Binding<TriState> {
    Binding(
      get: {
        switch selection {
        case .none: return .inherit
        case .some(true): return .yes
        case .some(false): return .no
        }
      },
      set: { newValue in
        switch newValue {
        case .inherit: selection = nil
        case .yes: selection = true
        case .no: selection = false
        }
      }
    )
  }

  var body: some View {
    Picker(title, selection: triBinding) {
      Text(Self.inheritLabel(inheritedValue: inheritedValue)).tag(TriState.inherit)
      Text("Yes").tag(TriState.yes)
      Text("No").tag(TriState.no)
    }
  }

  /// Pure helper exposed for tests.
  nonisolated static func inheritLabel(inheritedValue: Bool) -> String {
    "Global — \(inheritedValue ? "yes" : "no")"
  }
}
