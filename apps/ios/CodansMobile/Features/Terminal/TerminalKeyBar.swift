import CodansIPC
import SwiftUI
import UIKit

/// What the key bar does, as closures into the pane's store.
struct TerminalKeyBarActions {
  var key: (String) -> Void
  var text: (String) -> Void
  var modifier: (ModifierLatch.Modifier) -> Void
  var events: ([IPC.TerminalInputEvent]) -> Void
  var paste: () -> Void
  var compose: () -> Void
  var toggleKeyboard: () -> Void
}

/// The row above the software keyboard: Esc, Ctrl, Alt and Tab fixed on
/// the left; a scrolling middle with a D-pad, the symbols a phone
/// keyboard buries, navigation keys and F1–F12; Paste, Compose and the
/// keyboard toggle fixed on the right. Long-pressing Ctrl opens the
/// shortcut panel on the pane's agent's page.
struct TerminalKeyBar: View {
  let modifiers: ModifierLatch
  let isKeyboardShown: Bool
  let agent: String?
  let isEnabled: Bool
  let actions: TerminalKeyBarActions

  @State private var isPanelShown = false

  static let height: CGFloat = 48

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 4) {
        KeyCap("esc") { actions.key("Escape") }
        ModifierCap(title: "ctrl", mode: modifiers.ctrl) {
          actions.modifier(.ctrl)
        } onLongPress: {
          isPanelShown = true
        }
        .popover(isPresented: $isPanelShown, arrowEdge: .bottom) {
          TerminalShortcutPanel(initialPage: .defaultPage(forAgent: agent)) { events in
            isPanelShown = false
            actions.events(events)
          }
          .presentationCompactAdaptation(.popover)
        }
        ModifierCap(title: "alt", mode: modifiers.alt, action: { actions.modifier(.alt) })
        KeyCap("tab") { actions.key("Tab") }
      }
      .padding(.leading, 4)
      .padding(.trailing, 4)

      Divider().frame(height: 26)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          DPad { actions.key($0) }
          ForEach(["~", "|", "/", "\\", "-", "_"], id: \.self) { symbol in
            KeyCap(symbol, monospaced: true) { actions.text(symbol) }
          }
          KeyCap("home") { actions.key("Home") }
          KeyCap("end") { actions.key("End") }
          KeyCap("pgup", repeats: true) { actions.key("PageUp") }
          KeyCap("pgdn", repeats: true) { actions.key("PageDown") }
          KeyCap("⇧tab") { actions.events([.press("Tab", IPC.TerminalKeyModifiers(shift: true))]) }
          ForEach(1...12, id: \.self) { number in
            KeyCap("F\(number)") { actions.key("F\(number)") }
          }
        }
        .padding(.horizontal, 4)
      }
      .scrollClipDisabled(false)

      Divider().frame(height: 26)

      HStack(spacing: 0) {
        IconCap("doc.on.clipboard", label: "Paste", action: actions.paste)
        IconCap("square.and.pencil", label: "Compose", action: actions.compose)
        IconCap(
          isKeyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
          label: isKeyboardShown ? "Hide Keyboard" : "Show Keyboard",
          action: actions.toggleKeyboard)
      }
      .padding(.leading, 2)
      .padding(.trailing, 4)
    }
    .frame(height: Self.height)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-key-bar")
  }
}

// MARK: - Keys

/// Light tick on every key, like the system keyboard's.
@MainActor
enum KeyHaptics {
  private static let generator = UIImpactFeedbackGenerator(style: .light)

  static func tap() {
    generator.impactOccurred(intensity: 0.7)
  }
}

/// Darkens a key while it is held, like a keyboard key.
private struct KeyPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.55 : 1)
  }
}

private struct KeyCapStyle: ViewModifier {
  var isHighlighted = false

  func body(content: Content) -> some View {
    content
      .frame(minWidth: 30, minHeight: 34)
      .padding(.horizontal, 3)
      // Concrete colours: a hierarchical style on the fill would resolve
      // against the foreground set below and vanish.
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isHighlighted ? Color.primary : Color(uiColor: .tertiarySystemFill))
      )
      .foregroundStyle(isHighlighted ? Color(uiColor: .systemBackground) : Color.primary)
      // A plain rectangle: on iPad a rounded-rect hit shape sat about 24
      // points left of the drawn cap, so a tap on Ctrl latched Alt. The
      // corners are too small to matter to a finger.
      .contentShape(.rect)
  }
}

/// A key cap. A plain button so the scrolling middle still scrolls under
/// a finger; keys that repeat start repeating once held.
private struct KeyCap: View {
  let title: String
  var monospaced = false
  var repeats = false
  let action: () -> Void

  @State private var repeatTask: Task<Void, Never>?

  init(_ title: String, monospaced: Bool = false, repeats: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.monospaced = monospaced
    self.repeats = repeats
    self.action = action
  }

  var body: some View {
    Button(action: fire) {
      Text(title)
        .font(
          monospaced ? .system(size: 17, weight: .regular, design: .monospaced) : .system(size: 13, weight: .medium)
        )
        .modifier(KeyCapStyle())
    }
    .buttonStyle(KeyPressStyle())
    .onLongPressGesture(minimumDuration: 0.4, maximumDistance: 20) {
    } onPressingChanged: { pressing in
      guard repeats else { return }
      repeatTask?.cancel()
      repeatTask = nil
      guard pressing else { return }
      repeatTask = Task {
        try? await Task.sleep(for: .milliseconds(420))
        while !Task.isCancelled {
          fire()
          try? await Task.sleep(for: .milliseconds(60))
        }
      }
    }
    .onDisappear {
      // A key bar that goes away mid-press never reports the release.
      repeatTask?.cancel()
      repeatTask = nil
    }
    .accessibilityLabel(Self.spokenName(title))
    .accessibilityIdentifier("key-\(title)")
  }

  private func fire() {
    KeyHaptics.tap()
    action()
  }

  private static func spokenName(_ title: String) -> String {
    switch title {
    case "esc": return "Escape"
    case "tab": return "Tab"
    case "⇧tab": return "Shift Tab"
    case "pgup": return "Page Up"
    case "pgdn": return "Page Down"
    case "~": return "Tilde"
    case "|": return "Pipe"
    case "/": return "Slash"
    case "\\": return "Backslash"
    case "-": return "Dash"
    case "_": return "Underscore"
    default: return title.capitalized
    }
  }
}

/// Ctrl or Alt: filled while armed, with a bar underneath while locked.
private struct ModifierCap: View {
  let title: String
  let mode: ModifierLatch.Mode
  let action: () -> Void
  var onLongPress: (() -> Void)?

  var body: some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .modifier(KeyCapStyle(isHighlighted: mode != .off))
      .overlay(alignment: .bottom) {
        if mode == .locked {
          Capsule()
            .fill(Color(uiColor: .systemBackground))
            .frame(width: 16, height: 2.5)
            .padding(.bottom, 4)
        }
      }
      .onTapGesture {
        KeyHaptics.tap()
        action()
      }
      .onLongPressGesture(minimumDuration: 0.45) {
        guard let onLongPress else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onLongPress()
      }
      .accessibilityElement()
      .accessibilityLabel(title == "ctrl" ? "Control" : "Option")
      .accessibilityValue(mode == .locked ? "Locked" : mode == .armed ? "On" : "Off")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("key-\(title)")
      .accessibilityAction { action() }
      .accessibilityAction(named: "Shortcuts") { onLongPress?() }
  }
}

private struct IconCap: View {
  let symbol: String
  let label: String
  let action: () -> Void

  init(_ symbol: String, label: String, action: @escaping () -> Void) {
    self.symbol = symbol
    self.label = label
    self.action = action
  }

  var body: some View {
    Button {
      KeyHaptics.tap()
      action()
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .frame(width: 32, height: 34)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// Arrow keys in one key. A tap sends the arrow toward the side tapped;
/// dragging past a few points sends arrows in the drag's direction,
/// faster the further the finger goes, until it lifts.
private struct DPad: View {
  let send: (String) -> Void

  @State private var driver = DPadDriver()
  /// Resets when the drag ends or is cancelled; only a cancel leaves the
  /// driver running by then.
  @GestureState private var isDragging = false

  var body: some View {
    Image(systemName: driver.direction.map(Self.symbol) ?? "dpad")
      .font(.system(size: 18, weight: .regular))
      .frame(width: 44, height: 34)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(uiColor: .tertiarySystemFill))
      )
      // Rectangular for the reason in KeyCapStyle.
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .updating($isDragging) { _, dragging, _ in dragging = true }
          .onChanged { value in driver.update(translation: value.translation, send: send) }
          .onEnded { value in driver.end(at: value.location, in: CGSize(width: 44, height: 34), send: send) }
      )
      .onChange(of: isDragging) { _, dragging in
        guard !dragging else { return }
        // Deferred past `onEnded`, which SwiftUI may call after the reset;
        // after a normal end there is nothing left to cancel.
        Task { @MainActor in driver.cancel() }
      }
      .onDisappear { driver.cancel() }
      .accessibilityElement()
      .accessibilityLabel("Arrow keys")
      .accessibilityAdjustableAction { direction in
        send(direction == .increment ? "ArrowUp" : "ArrowDown")
      }
      .accessibilityIdentifier("key-dpad")
  }

  private static func symbol(_ code: String) -> String {
    switch code {
    case "ArrowUp": return "dpad.up.filled"
    case "ArrowDown": return "dpad.down.filled"
    case "ArrowLeft": return "dpad.left.filled"
    default: return "dpad.right.filled"
    }
  }
}

/// The D-pad's drag state and repeat loop, outside SwiftUI's value types
/// so the loop reads the latest finger position.
@MainActor
@Observable
final class DPadDriver {
  private(set) var direction: String?
  @ObservationIgnored private var distance: CGFloat = 0
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var didDrag = false

  /// Points of travel before a drag counts as one.
  nonisolated static let threshold: CGFloat = 10

  // Explicit: a synthesized isolated deinit on a SwiftUI-owned observable
  // has crashed on release.
  deinit {}

  func update(translation: CGSize, send: @escaping (String) -> Void) {
    let dx = translation.width
    let dy = translation.height
    distance = max(abs(dx), abs(dy))
    guard distance >= Self.threshold else { return }
    didDrag = true
    let next = abs(dx) > abs(dy) ? (dx > 0 ? "ArrowRight" : "ArrowLeft") : (dy > 0 ? "ArrowDown" : "ArrowUp")
    guard next != direction else { return }
    direction = next
    KeyHaptics.tap()
    send(next)
    loop?.cancel()
    loop = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      while !Task.isCancelled, let self, let direction = self.direction {
        send(direction)
        try? await Task.sleep(for: .milliseconds(Self.interval(forDistance: self.distance)))
      }
    }
  }

  func end(at location: CGPoint, in size: CGSize, send: (String) -> Void) {
    loop?.cancel()
    loop = nil
    if !didDrag {
      // A tap: the arrow toward the side of the key that was touched.
      let dx = (location.x - size.width / 2) / size.width
      let dy = (location.y - size.height / 2) / size.height
      let code = abs(dx) > abs(dy) ? (dx > 0 ? "ArrowRight" : "ArrowLeft") : (dy > 0 ? "ArrowDown" : "ArrowUp")
      KeyHaptics.tap()
      send(code)
    }
    direction = nil
    distance = 0
    didDrag = false
  }

  /// Stops the drag without the tap `end` would send. SwiftUI does not
  /// call a drag's `onEnded` when the gesture is cancelled (the key bar
  /// goes away, the system takes the touch), and without this the repeat
  /// would keep typing arrows into the pane.
  func cancel() {
    loop?.cancel()
    loop = nil
    direction = nil
    distance = 0
    didDrag = false
  }

  var isRepeating: Bool { loop != nil }

  /// Milliseconds between repeats: 160 near the key, down to 30 far out.
  nonisolated static func interval(forDistance distance: CGFloat) -> Int {
    let scaled = 160 - Int((distance - threshold) * 3)
    return min(160, max(30, scaled))
  }
}

// MARK: - Shortcut panel

/// Agent commands, tmux and Ctrl letters, one tap each.
struct TerminalShortcutPanel: View {
  let send: ([IPC.TerminalInputEvent]) -> Void
  @State private var page: TerminalShortcutPage

  init(initialPage: TerminalShortcutPage, send: @escaping ([IPC.TerminalInputEvent]) -> Void) {
    self.send = send
    _page = State(initialValue: initialPage)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Shortcuts", selection: $page) {
        ForEach(TerminalShortcutPage.allCases) { page in
          Text(page.title).tag(page)
        }
      }
      .pickerStyle(.segmented)

      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(page.shortcuts) { shortcut in
          Button {
            KeyHaptics.tap()
            send(shortcut.events)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(shortcut.title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
              Text(shortcut.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.fill.tertiary))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("shortcut-\(shortcut.title)")
        }
      }
    }
    .padding(14)
    .frame(width: 320)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("shortcut-panel")
  }
}
