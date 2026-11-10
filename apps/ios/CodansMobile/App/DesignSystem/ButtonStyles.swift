import SwiftUI

/// The primary action: an ink capsule with the page colour's label.
struct InkButtonStyle: ButtonStyle {
  var isCompact = false

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(isCompact ? .system(size: 14, weight: .semibold) : .system(size: 16, weight: .semibold))
      .foregroundStyle(Color.onInk)
      .padding(.horizontal, isCompact ? 14 : 22)
      .frame(minHeight: isCompact ? 32 : 48)
      .frame(maxWidth: isCompact ? nil : 320)
      .background(Color.ink.opacity(isEnabled ? 1 : 0.3), in: .capsule)
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(.capsule)
  }
}

/// A secondary action: ink label on a muted capsule.
struct QuietButtonStyle: ButtonStyle {
  var isCompact = false

  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(isCompact ? .system(size: 14, weight: .semibold) : .system(size: 16, weight: .medium))
      .foregroundStyle(isEnabled ? Color.ink : Color.inkTertiary)
      .padding(.horizontal, isCompact ? 12 : 22)
      .frame(minHeight: isCompact ? 30 : 48)
      .background(Color.surfaceMuted, in: .capsule)
      .opacity(configuration.isPressed ? 0.6 : 1)
      .contentShape(.capsule)
  }
}

/// A button over the always-dark terminal: a white capsule for the main
/// action, a translucent one for the rest. Ink would flip to black on
/// black in light mode.
struct TerminalButtonStyle: ButtonStyle {
  var isProminent = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(isProminent ? Color.black : Color.white)
      .padding(.horizontal, 14)
      .frame(minHeight: 32)
      .background(isProminent ? Color.white : Color.white.opacity(0.14), in: .capsule)
      .opacity(configuration.isPressed ? 0.7 : 1)
      .contentShape(.capsule)
  }
}

extension ButtonStyle where Self == TerminalButtonStyle {
  static var terminal: TerminalButtonStyle { TerminalButtonStyle() }
  static var terminalQuiet: TerminalButtonStyle { TerminalButtonStyle(isProminent: false) }
}

extension ButtonStyle where Self == InkButtonStyle {
  static var ink: InkButtonStyle { InkButtonStyle() }
  static var inkCompact: InkButtonStyle { InkButtonStyle(isCompact: true) }
}

extension ButtonStyle where Self == QuietButtonStyle {
  static var quiet: QuietButtonStyle { QuietButtonStyle() }
  static var quietCompact: QuietButtonStyle { QuietButtonStyle(isCompact: true) }
}

/// The send button: an ink circle with an arrow; muted while it cannot
/// send, a spinner while sending.
struct PrimaryCircleButton: View {
  var systemImage = "arrow.up"
  var isEnabled = true
  var isBusy = false
  var size: CGFloat = 36
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(isEnabled || isBusy ? Color.ink : Color.surfaceMuted)
        if isBusy {
          ProgressView()
            .tint(Color.onInk)
            .controlSize(.small)
        } else {
          Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.onInk : Color.inkTertiary)
        }
      }
      .frame(width: size, height: size)
      .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled || isBusy)
  }
}
