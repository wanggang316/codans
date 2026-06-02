import AppKit
import SwiftUI
import TouchCodeCore

/// Raycast-style chord recorder popover.
///
/// Sits inside `.popover(isPresented:)` from a row's chord button. Self-owns the recorder
/// `NSView` (mounted as a 0×0 background) and fans live `flagsChanged` previews into the
/// SwiftUI body so users see modifier keycaps light up before they tap a non-modifier key.
///
/// Three terminal states:
///
/// - `.recorded` — chord captured; popover shows a green `Recorded! ✓` row and dismisses
///   itself after a short delay via `onCommit`.
/// - `.rejected` — caller's `validate` reported a hard rejection (system-reserved chord,
///   AppKit-reserved chord, internal validator failure). Popover shakes, displays the
///   message in red, then returns to listening after ~1.5 s.
/// - cancel via Escape, the close button, or click-outside dismissal — `onCancel` fires
///   and the parent dismisses the popover.
///
/// `onCommit` is called with the validated binding only on `.recorded`; the parent runs
/// `ShortcutsStore.update` and any post-commit dialogs (cascading-reset preview, etc.) on
/// the same dispatch tick.
struct HotkeyRecorderPopover: View {
  /// Display name for this command — rendered in the header.
  let title: String
  /// Validate the captured binding before committing. Returning `.ok` commits the chord;
  /// returning `.rejected(message)` keeps the popover open with the message in red.
  let validate: (ShortcutBinding) -> ValidationResult
  /// Called once on the `.recorded` path right before the popover auto-dismisses. Parent
  /// is responsible for invoking `ShortcutsStore.update` (or `resolveConflict`).
  let onCommit: (ShortcutBinding) -> Void
  /// Called whenever the popover requests dismissal: Escape, close button, post-commit
  /// auto-dismiss, or shake-and-recover when the parent doesn't reset state externally.
  let onCancel: () -> Void
  /// Optional "Clear" action. When non-nil, the popover shows a Clear button that removes
  /// the existing chord — used by per-command script shortcuts, where "no shortcut" is a
  /// valid state. The system Shortcuts page omits this: its rows always carry a schema
  /// default and use Disable/Enable instead, so clearing has no meaning there.
  var onClear: (() -> Void)?

  enum ValidationResult: Equatable {
    case ok
    case rejected(message: String)
  }

  private enum Stage: Equatable {
    case listening
    case recorded(ShortcutBinding)
    case rejected(binding: ShortcutBinding, message: String)
  }

  @State private var activeModifiers: ModifierMask = []
  @State private var stage: Stage = .listening
  @State private var shakeOffset: CGFloat = 0
  @State private var dismissTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 10) {
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Group {
        switch stage {
        case .listening:
          listeningRow
        case .recorded(let binding):
          KeycapsRow(binding: binding)
        case .rejected(let binding, _):
          KeycapsRow(binding: binding)
        }
      }
      .frame(minHeight: 32)

      Group {
        switch stage {
        case .listening:
          Text("Press the new shortcut")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .recorded:
          Label("Recorded", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        case .rejected(_, let message):
          Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
        }
      }

      if let onClear {
        Divider()
        Button {
          dismissTask?.cancel()
          onClear()
        } label: {
          Text("Clear Shortcut")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .frame(width: 240)
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
    .offset(x: shakeOffset)
    .overlay(alignment: .topTrailing) {
      Button {
        cancel()
      } label: {
        Image(systemName: "xmark")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Cancel")
      }
      .buttonStyle(.plain)
      .padding(8)
    }
    .background {
      // 0×0 NSView captures keyDown / flagsChanged. Lives only while the popover body is
      // mounted; SwiftUI tears it down on dismiss, which removes the NSEvent monitor.
      HotkeyRecorderRepresentable(
        onCapture: handleCapture,
        onReject: handleReject,
        onCancel: cancel,
        onModifiersChanged: { activeModifiers = $0 }
      )
      .frame(width: 0, height: 0)
    }
  }

  // MARK: - Body fragments

  @ViewBuilder
  private var listeningRow: some View {
    HStack(spacing: 4) {
      if activeModifiers.isEmpty {
        Keycap(symbol: "⇧", muted: true)
        Keycap(symbol: "⌘", muted: true)
        Keycap(symbol: "Space", muted: true)
      } else {
        if activeModifiers.contains(.control) { Keycap(symbol: "⌃") }
        if activeModifiers.contains(.option) { Keycap(symbol: "⌥") }
        if activeModifiers.contains(.shift) { Keycap(symbol: "⇧") }
        if activeModifiers.contains(.command) { Keycap(symbol: "⌘") }
      }
    }
  }

  // MARK: - Capture pipeline

  private func handleCapture(_ binding: ShortcutBinding) {
    dismissTask?.cancel()
    switch validate(binding) {
    case .ok:
      stage = .recorded(binding)
      onCommit(binding)
      dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        onCancel()
      }
    case .rejected(let message):
      stage = .rejected(binding: binding, message: message)
      shake()
      dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1400))
        guard !Task.isCancelled else { return }
        stage = .listening
      }
    }
  }

  private func handleReject(_ reason: HotkeyRecorderNSView.RejectionReason) {
    let message: String
    switch reason {
    case .missingPrimaryModifier: message = "Add ⌘, ⌥, or ⌃."
    case .modifierOnly: message = "Press a non-modifier key."
    }
    let placeholder = ShortcutBinding(
      keyCode: 0,
      modifiers: activeModifiers.isEmpty ? .command : activeModifiers
    )
    stage = .rejected(binding: placeholder, message: message)
    shake()
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1100))
      guard !Task.isCancelled else { return }
      stage = .listening
    }
  }

  private func cancel() {
    dismissTask?.cancel()
    onCancel()
  }

  private func shake() {
    let offsets: [(CGFloat, Double)] = [(-8, 0.06), (8, 0.12), (-4, 0.18), (0, 0.24)]
    for (offset, deadline) in offsets {
      DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
        withAnimation(.linear(duration: 0.06)) { shakeOffset = offset }
      }
    }
  }
}

// MARK: - Keycap

/// Single-symbol keycap rendered with a quaternary-fill rounded rectangle. `muted` knocks
/// opacity down for the placeholder hint shown before the user has pressed any modifier.
struct Keycap: View {
  let symbol: String
  var muted: Bool = false

  var body: some View {
    Text(symbol)
      .font(.system(size: 13, weight: .medium, design: .monospaced))
      .padding(.horizontal, 6)
      .frame(minWidth: 26, minHeight: 26)
      .background(.quaternary, in: .rect(cornerRadius: 5))
      .opacity(muted ? 0.45 : 1.0)
  }
}

private struct KeycapsRow: View {
  let binding: ShortcutBinding

  var body: some View {
    HStack(spacing: 4) {
      ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
        Keycap(symbol: symbol)
      }
    }
  }

  /// Decompose a `ShortcutBinding` into the canonical `⌃⌥⇧⌘ + key` keycap sequence used by
  /// macOS menus. Skips the trailing key when `keyCode == 0` (the placeholder used during
  /// validation rejection — there's no real key to render).
  private var symbols: [String] {
    var out: [String] = []
    if binding.modifiers.contains(.control) { out.append("⌃") }
    if binding.modifiers.contains(.option) { out.append("⌥") }
    if binding.modifiers.contains(.shift) { out.append("⇧") }
    if binding.modifiers.contains(.command) { out.append("⌘") }
    if binding.keyCode != 0 {
      out.append(ShortcutDisplay.keycap(for: binding.keyCode))
    }
    return out
  }
}

// MARK: - NSViewRepresentable

private struct HotkeyRecorderRepresentable: NSViewRepresentable {
  var onCapture: (ShortcutBinding) -> Void
  var onReject: (HotkeyRecorderNSView.RejectionReason) -> Void
  var onCancel: () -> Void
  var onModifiersChanged: (ModifierMask) -> Void

  func makeNSView(context: Context) -> HotkeyRecorderNSView {
    let view = HotkeyRecorderNSView(frame: .zero)
    view.onCapture = onCapture
    view.onReject = onReject
    view.onCancel = onCancel
    view.onModifiersChanged = onModifiersChanged
    DispatchQueue.main.async { view.beginRecording() }
    return view
  }

  func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
    nsView.onCapture = onCapture
    nsView.onReject = onReject
    nsView.onCancel = onCancel
    nsView.onModifiersChanged = onModifiersChanged
    if !nsView.isRecording {
      nsView.beginRecording()
    }
  }

  static func dismantleNSView(_ nsView: HotkeyRecorderNSView, coordinator: ()) {
    nsView.endRecording()
  }
}
