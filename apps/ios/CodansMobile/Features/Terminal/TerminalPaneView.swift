import CodansIPC
import ComposableArchitecture
import SwiftUI
import UIKit

/// Keyboard state for the pane that takes the keyboard. Shared between the
/// pane (a tap on its screen raises the keyboard; its composition bubble)
/// and the input chrome, which on the iPad sits under the whole split
/// layout rather than inside one pane.
@MainActor
@Observable
final class TerminalKeyboardState {
  var isFocused = false
  var showsSoftwareKeyboard = false
  /// IME composition in progress, floated over the pane until committed.
  var markedText: String?
  var isComposing = false

  // Explicit: a synthesized isolated deinit on a SwiftUI-owned observable
  // has crashed on release.
  deinit {}

  func raiseKeyboard() {
    isFocused = true
    showsSoftwareKeyboard = true
  }
}

/// One pane's live terminal with everything around it: the connecting,
/// reconnecting, exited and failed states, the "not open on your Mac"
/// notice, rejection toasts, the jump-to-bottom button and the IME
/// composition bubble. With `showsInputChrome` it also carries the key
/// bar and compose card underneath; the iPad split layout instead shows
/// one shared `TerminalInputChrome` under all its panes.
struct TerminalPaneView: View {
  @Bindable var store: StoreOf<TerminalStreamFeature>
  let agent: String?
  /// The keyboard state when this pane takes the keyboard; nil for the
  /// iPad's other split panes.
  var keyboard: TerminalKeyboardState?
  var showsInputChrome = true
  var onShortcut: (TerminalHardwareShortcut) -> Void = { _ in }
  var onCloseRequested: () -> Void = {}
  /// What the connection to the Mac is doing, shown instead of "Connecting
  /// to the terminal" while the session itself is not live yet.
  var connectionStatus: String?

  private var hasKeyboard: Bool { keyboard != nil && store.isInteractive }

  var body: some View {
    VStack(spacing: 0) {
      screen
        .overlay(alignment: .top) { topNotices }
        .overlay(alignment: .bottom) { bottomOverlays }
      if showsInputChrome, let keyboard, store.isInteractive {
        TerminalInputChrome(store: store, agent: agent, keyboard: keyboard, onShortcut: onShortcut)
      }
    }
    // Down into the home indicator area when nothing sits below the
    // screen, but never up under the navigation bar, which keeps the
    // app's appearance.
    .background(MirrorTerminalView.background.swiftUIColor, ignoresSafeAreaEdges: .bottom)
    .task { store.send(.task) }
  }

  // MARK: - Screen

  @ViewBuilder
  private var screen: some View {
    ZStack {
      MirrorTerminalView.background.swiftUIColor
      if store.grid != nil {
        TerminalScreen(model: store.screen) {
          guard hasKeyboard else { return }
          keyboard?.raiseKeyboard()
        }
        .opacity(store.isStale ? 0.35 : 1)
        .themeAnimation(store.isStale)
        .accessibilityIdentifier("terminal-screen")
      }
      switch store.phase {
      case .connecting:
        if store.grid == nil {
          TerminalConnectingView(
            message: store.isConnected ? "Connecting to the terminal…" : connectionStatus ?? "Waiting for your Mac…")
        }
      case .reconnecting:
        // While the Mac itself is unreachable the banner above the
        // terminal says so; this is for a stream dropping on its own.
        StatusCapsule(symbol: "arrow.triangle.2.circlepath", text: "Reconnecting…", animates: true)
          .opacity(store.isConnected ? 1 : 0)
          .accessibilityIdentifier("terminal-reconnecting")
      case .failed(let message):
        TerminalFailedView(message: message) { store.send(.retryAttach) }
      case .live, .exited:
        if store.isStale {
          StatusCapsule(symbol: "arrow.triangle.2.circlepath", text: "Reconnecting…", animates: true)
            .opacity(store.isConnected ? 1 : 0)
            .accessibilityIdentifier("terminal-reconnecting")
        }
      }
    }
    .clipped()
  }

  @ViewBuilder
  private var topNotices: some View {
    if store.notice == .paneNotOpenOnMac {
      TerminalNotice(
        symbol: "macwindow",
        title: "Not open on your Mac",
        message: "Keys need the pane's terminal open in Codans on your Mac.",
        actionTitle: "Open on Mac",
        action: { store.send(.openOnMacTapped) }
      )
      .padding(.horizontal, Theme.Space.sm)
      .padding(.top, Theme.Space.xs)
      .transition(.opacity)
    } else if store.fidelity == .approximate, store.phase == .live {
      Text("Approximate — restart the pane on your Mac for an exact view")
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: .capsule)
        .padding(.top, 6)
    }
  }

  @ViewBuilder
  private var bottomOverlays: some View {
    VStack(spacing: 8) {
      if let toast = store.toast {
        Text(toast)
          .font(.footnote)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.regularMaterial, in: .capsule)
          .environment(\.colorScheme, .dark)
          .transition(.opacity)
          .accessibilityIdentifier("terminal-toast")
      }
      if hasKeyboard, let markedText = keyboard?.markedText {
        // The composition floats here until the input method commits it;
        // none of it has reached the pane.
        Text(markedText)
          .font(.system(.body, design: .monospaced))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(.thickMaterial, in: .rect(cornerRadius: 10))
          .overlay(alignment: .bottom) {
            Rectangle().fill(.primary).frame(height: 1.5).padding(.horizontal, 10).padding(.bottom, 4)
          }
          .accessibilityIdentifier("terminal-composition")
      }
      if case .exited(let reason) = store.phase {
        TerminalExitedBanner(reason: reason, canClose: store.isInteractive, onClose: onCloseRequested)
      }
      HStack {
        Spacer()
        if store.grid != nil, !store.screen.isFollowingBottom {
          Button {
            store.screen.jumpToBottom()
          } label: {
            Image(systemName: "arrow.down.to.line")
              .font(.system(size: 15, weight: .semibold))
              .frame(width: 40, height: 40)
              .background(.regularMaterial, in: .circle)
              .environment(\.colorScheme, .dark)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Jump to Bottom")
          .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.trailing, 12)
    }
    .padding(.bottom, 10)
    .themeAnimation(store.toast)
    .themeAnimation(store.screen.isFollowingBottom)
  }
}

// MARK: - Input chrome

/// What sits under the terminal that has the keyboard: the key bar or the
/// compose card, plus the invisible `TerminalInputView` that is first
/// responder. The key bar hides while a hardware keyboard is attached.
struct TerminalInputChrome: View {
  @Bindable var store: StoreOf<TerminalStreamFeature>
  let agent: String?
  let keyboard: TerminalKeyboardState
  var onShortcut: (TerminalHardwareShortcut) -> Void = { _ in }

  @State private var keyboardMonitor = HardwareKeyboardMonitor()

  private var showsKeyBar: Bool {
    !keyboard.isComposing && (!keyboardMonitor.isConnected || DemoMode.forcesKeyBar)
  }

  var body: some View {
    @Bindable var keyboard = keyboard
    VStack(spacing: 0) {
      if keyboard.isComposing {
        TerminalComposeCard(
          draft: $store.composeDraft,
          isEnabled: store.canSendInput,
          onSend: { pressEnter in
            store.send(.composeSubmitted(pressEnter: pressEnter))
          },
          onClose: {
            keyboard.isComposing = false
            keyboard.isFocused = true
          }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
      } else if showsKeyBar {
        keyBar
      }
    }
    .background {
      TerminalInputBridge(
        isFocused: $keyboard.isFocused,
        showsSoftwareKeyboard: keyboard.showsSoftwareKeyboard,
        handlers: inputHandlers
      )
      .frame(width: 1, height: 1)
      .accessibilityHidden(true)
    }
    .themeAnimation(keyboard.isComposing)
    .onAppear { keyboard.isFocused = true }
    .onDisappear {
      keyboard.isFocused = false
      keyboard.markedText = nil
    }
  }

  private var keyBar: some View {
    TerminalKeyBar(
      modifiers: store.modifiers,
      isKeyboardShown: keyboard.showsSoftwareKeyboard && keyboard.isFocused,
      agent: agent,
      isEnabled: store.canSendInput,
      actions: TerminalKeyBarActions(
        key: { store.send(.keyPressed(code: $0, mods: .none)) },
        text: { store.send(.textTyped($0)) },
        modifier: { store.send(.modifierTapped($0)) },
        events: { events in
          store.send(.eventsRequested(events))
          keyboard.isFocused = true
        },
        paste: {
          if let text = UIPasteboard.general.string, !text.isEmpty {
            store.send(.eventsRequested([.paste(text)]))
          }
        },
        compose: {
          keyboard.isFocused = false
          keyboard.isComposing = true
        },
        toggleKeyboard: {
          if keyboard.isFocused, keyboard.showsSoftwareKeyboard {
            keyboard.showsSoftwareKeyboard = false
          } else {
            keyboard.raiseKeyboard()
          }
        }
      )
    )
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .overlay {
      if let reason = store.inputDisabledReason {
        Text(reason)
          .font(.rowDetail)
          .foregroundStyle(Color.inkSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.bar)
      }
    }
  }

  private var inputHandlers: TerminalInputBridge.Handlers {
    TerminalInputBridge.Handlers(
      text: { store.send(.textTyped($0)) },
      key: { store.send(.keyPressed(code: $0, mods: $1)) },
      paste: { store.send(.eventsRequested([.paste($0)])) },
      markedText: { keyboard.markedText = $0 },
      shortcut: { shortcut in
        switch shortcut {
        case .zoomIn: store.screen.zoom(by: 1.25)
        case .zoomOut: store.screen.zoom(by: 0.8)
        case .clear: store.send(.eventsRequested([.ctrl("l")]))
        default: onShortcut(shortcut)
        }
      }
    )
  }
}

// MARK: - Input bridge

/// Puts a `TerminalInputView` in the hierarchy and keeps its first
/// responder state in step with `isFocused`.
struct TerminalInputBridge: UIViewRepresentable {
  struct Handlers {
    var text: (String) -> Void
    var key: (String, IPC.TerminalKeyModifiers) -> Void
    var paste: (String) -> Void
    var markedText: (String?) -> Void
    var shortcut: (TerminalHardwareShortcut) -> Void
  }

  @Binding var isFocused: Bool
  let showsSoftwareKeyboard: Bool
  let handlers: Handlers

  func makeUIView(context: Context) -> TerminalInputView {
    let view = TerminalInputView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    view.backgroundColor = .clear
    return view
  }

  func updateUIView(_ view: TerminalInputView, context: Context) {
    view.onText = handlers.text
    view.onKey = handlers.key
    view.onPaste = handlers.paste
    view.onMarkedTextChange = handlers.markedText
    view.onShortcut = handlers.shortcut
    view.showsSoftwareKeyboard = showsSoftwareKeyboard
    let wantsFocus = isFocused
    // Responder changes during a SwiftUI update are deferred to after it.
    DispatchQueue.main.async {
      if wantsFocus, !view.isFirstResponder, view.window != nil {
        view.becomeFirstResponder()
      } else if !wantsFocus, view.isFirstResponder {
        view.resignFirstResponder()
      }
    }
  }
}

// MARK: - States

private struct TerminalConnectingView: View {
  let message: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(0..<6, id: \.self) { row in
        RoundedRectangle(cornerRadius: 3)
          .fill(.white.opacity(0.08))
          .frame(width: [220, 160, 250, 120, 190, 90][row], height: 10)
      }
      Text(message)
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.6))
        .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(16)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("terminal-connecting")
  }
}

private struct TerminalFailedView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .accessibilityHidden(true)
        .font(.title2)
      Text("Can't show this terminal")
        .font(.headline)
      Text(message)
        .font(.footnote)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(0.7))
      Button("Try Again", action: retry)
        .buttonStyle(.terminal)
    }
    .foregroundStyle(.white)
    .padding(24)
    .frame(maxWidth: 320)
  }
}

/// A small pill over the dimmed screen.
struct StatusCapsule: View {
  let symbol: String
  let text: String
  var animates = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: symbol)
        .accessibilityHidden(true)
        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: animates && !reduceMotion)
    }
    .font(.subheadline.weight(.medium))
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.black.opacity(0.65), in: .capsule)
    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
  }
}

private struct TerminalExitedBanner: View {
  let reason: String
  let canClose: Bool
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.sm) {
      StatusDot(color: .offline)
      VStack(alignment: .leading, spacing: 1) {
        Text("Process exited")
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        if !reason.isEmpty {
          Text(reason)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.65))
            .lineLimit(1)
        }
      }
      Spacer(minLength: Theme.Space.xs)
      if canClose {
        Button("Close Pane", role: .destructive, action: onClose)
          .buttonStyle(.terminalQuiet)
          // A narrow split pane squeezes the text, never the button.
          .fixedSize()
      }
    }
    .terminalBanner()
    .padding(.horizontal, Theme.Space.sm)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-exited")
  }
}

/// A notice with one action, over the top of the screen.
struct TerminalNotice: View {
  let symbol: String
  let title: String
  let message: String
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: Theme.Space.sm) {
      Image(systemName: symbol)
        .accessibilityHidden(true)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Color.needsInput)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.65))
      }
      Spacer(minLength: Theme.Space.xs)
      Button(actionTitle, action: action)
        .buttonStyle(.terminal)
        .fixedSize()
    }
    .terminalBanner()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-notice")
  }
}

extension View {
  /// The terminal's counterpart of `InlineBanner`'s card: the same shape
  /// and padding, dark whatever the app's appearance, since it sits on the
  /// always-dark screen.
  func terminalBanner() -> some View {
    foregroundStyle(.white)
      .padding(.leading, Theme.Space.md)
      .padding(.trailing, Theme.Space.sm)
      .padding(.vertical, 10)
      .background(
        Color(white: 0.1).opacity(0.92), in: .rect(cornerRadius: Theme.Radius.card, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(.white.opacity(0.12))
      }
      .environment(\.colorScheme, .dark)
  }
}

extension UIColor {
  var swiftUIColor: Color { Color(uiColor: self) }
}
