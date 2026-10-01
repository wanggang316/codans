import SwiftUI

/// A full-page state: what happened, what to check, and the one action that
/// fixes it. For states with nothing else to show — no Mac found, access
/// denied, device removed, update needed, not paired.
struct StateView: View {
  let symbol: String
  var tint: Color = .ink
  let title: String
  var message: String?
  /// Things to check, in order, shown as a short checklist.
  var checklist: [String] = []
  /// A quiet line above the actions, e.g. a retry countdown.
  var status: String?
  var primary: Action?
  var secondary: Action?

  struct Action {
    let title: String
    var identifier: String?
    let perform: () -> Void

    init(_ title: String, identifier: String? = nil, perform: @escaping () -> Void) {
      self.title = title
      self.identifier = identifier
      self.perform = perform
    }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: Theme.Space.lg) {
        Image(systemName: symbol)
          .font(.system(size: 26, weight: .regular))
          .foregroundStyle(tint)
          .frame(width: 64, height: 64)
          .background(Color.surfaceElevated, in: .circle)
          .overlay(Circle().strokeBorder(Color.hairline))
          .accessibilityHidden(true)

        VStack(spacing: Theme.Space.xs) {
          Text(title)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.ink)
          if let message {
            Text(message)
              .font(.system(size: 15))
              .foregroundStyle(Color.inkSecondary)
          }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)

        if !checklist.isEmpty {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(checklist.enumerated()), id: \.offset) { index, item in
              HStack(spacing: Theme.Space.sm) {
                Text("\(index + 1)")
                  .font(.system(size: 12, weight: .semibold).monospacedDigit())
                  .foregroundStyle(Color.inkSecondary)
                  .frame(width: 22, height: 22)
                  .background(Color.surfaceMuted, in: .circle)
                Text(item)
                  .font(.system(size: 15))
                  .foregroundStyle(Color.ink)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.vertical, 11)
              .padding(.horizontal, Theme.Space.md)
              if index < checklist.count - 1 {
                Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 50)
              }
            }
          }
          .background(Color.surfaceElevated, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.hairline)
          }
          .frame(maxWidth: 360)
          .accessibilityElement(children: .combine)
        }

        if let status {
          Text(status)
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(Color.inkTertiary)
        }

        if primary != nil || secondary != nil {
          VStack(spacing: Theme.Space.xs) {
            if let primary {
              Button(primary.title, action: primary.perform)
                .buttonStyle(.ink)
                .accessibilityIdentifier(primary.identifier ?? "")
            }
            if let secondary {
              Button(secondary.title, action: secondary.perform)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.inkSecondary)
                .padding(.vertical, Theme.Space.xs)
                .accessibilityIdentifier(secondary.identifier ?? "")
            }
          }
          .frame(maxWidth: 320)
          .padding(.top, Theme.Space.xxs)
        }
      }
      .padding(.horizontal, Theme.Space.lg)
      .padding(.vertical, 48)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.center)
  }
}
