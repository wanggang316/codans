import SwiftUI
import CodansCore

/// Renders a single `StatusToast`. Leading glyph (✓ / ▲) + secondary message.
/// Intentionally small — the toolbar center slot is a one-line summary, not a
/// banner. Priority and auto-clear live in `StatusBarFeature`; this view is a
/// pure projection of `toast`.
struct StatusToastView: View {
  let toast: StatusToast
  /// When true, renders glyph only. Driven by `ViewThatFits` in narrow
  /// titlebars — the AX label and tooltip still carry the message.
  var compact: Bool = false

  var body: some View {
    HStack(spacing: 6) {
      glyph
      if !compact {
        Text(toast.displayMessage)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .help(toast.message)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(for: toast))
    .accessibilityValue(toast.message)
    .accessibilityIdentifier("status.toast")
  }

  @ViewBuilder
  private var glyph: some View {
    switch toast {
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    case .warning:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    }
  }

  static func accessibilityLabel(for toast: StatusToast) -> String {
    switch toast {
    case .success: return "Success"
    case .warning: return "Warning"
    }
  }
}
