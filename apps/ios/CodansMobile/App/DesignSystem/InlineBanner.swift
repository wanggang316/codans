import SwiftUI

/// A non-blocking strip above content: a status dot, a title, a detail
/// line and at most one action. Used for reconnecting, offline and stale
/// states; the content under it stays usable.
struct InlineBanner<Detail: View>: View {
  let color: Color
  var pulses = false
  let title: String
  @ViewBuilder let detail: () -> Detail
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack(spacing: Theme.Space.sm) {
      StatusDot(color: color, pulses: pulses)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.ink)
          .lineLimit(1)
        detail()
          .font(.system(size: 12))
          .foregroundStyle(Color.inkSecondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.quietCompact)
          .fixedSize()
      }
    }
    .padding(.leading, Theme.Space.md)
    .padding(.trailing, Theme.Space.sm)
    .padding(.vertical, 10)
    .background(Color.surfaceElevated, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.hairline)
    }
    .accessibilityElement(children: .combine)
  }
}
