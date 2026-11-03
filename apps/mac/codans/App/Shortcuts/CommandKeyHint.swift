import AppKit
import SwiftUI
import CodansCore

extension View {
  /// While the user holds ⌘, append the chord bound to `id` after this view —
  /// inline in the same `HStack`, so the chord becomes part of the button /
  /// label it decorates rather than a floating overlay. Visually matches the
  /// macOS menu convention "Item Name  ⌘⇧O".
  ///
  /// Apply this on the *label* of a Button / Menu (not the Button itself) so
  /// the chord text stays inside the button's hit area and lays out with the
  /// rest of the label content. Reads `CommandKeyObserver` and
  /// `\.resolvedShortcuts` from the environment, both already injected at the
  /// main scene root. Renders nothing while ⌘ is not held, when the resolved
  /// entry is missing/disabled, or when the chord has no displayable binding.
  ///
  /// `spacing` is the gap between the decorated view and the chord. The
  /// default suits a bare glyph or text. A view that already pads its glyph
  /// inside a fixed frame (the tab bar's 22pt hover circle) should pass a
  /// smaller value, otherwise the chord sits farther from its own icon than
  /// from the next button and reads as belonging to the wrong one.
  func commandKeyHint(_ id: CommandID, spacing: CGFloat = 6) -> some View {
    modifier(CommandKeyHintModifier(id: id, spacing: spacing))
  }

  /// Variant for chords that are NOT backed by a `CommandID` — e.g. a
  /// per-project run script whose binding lives in settings, or a fixed chord
  /// like ⌘. for "stop". Pass the already-resolved display string (`nil` shows
  /// nothing); it is appended after this view while ⌘ is held, matching the
  /// `commandKeyHint(_:spacing:)` convention. The observer dependency lives in
  /// the modifier, so the hint appears/disappears live even inside a toolbar
  /// Menu label (where reads in the `label:` closure itself would escape
  /// tracking).
  func commandKeyHint(chord: String?, spacing: CGFloat = 6) -> some View {
    modifier(CommandKeyChordHintModifier(chord: chord, spacing: spacing))
  }

  /// While the user holds ⌘, hide this glyph and show the chord bound to `id` in its
  /// place, in the hint style of the sidebar filter buttons (`.caption`, secondary).
  /// Apply it on the *label* of a toolbar `Menu(primaryAction:)`. AppKit draws that
  /// label as the image of a segmented control and drops SwiftUI opacity and layering,
  /// so the label swaps its whole content: the glyph while ⌘ is up, an image of the
  /// chord while ⌘ is held.
  func commandKeyHintReplacing(_ id: CommandID) -> some View {
    modifier(CommandKeyHintReplacingModifier(id: id))
  }
}

private struct CommandKeyHintReplacingModifier: ViewModifier {
  let id: CommandID
  @Environment(CommandKeyObserver.self) private var observer
  @Environment(\.resolvedShortcuts) private var shortcuts

  func body(content: Content) -> some View {
    if observer.isCommandHeld, let chord = ShortcutDisplay.chord(for: id, in: shortcuts) {
      Image(nsImage: Self.image(of: chord))
        .renderingMode(.original)
        .accessibilityHidden(true)
    } else {
      content
    }
  }

  /// The chord drawn as `ShortcutHintLabel` draws it. The color resolves when AppKit
  /// draws the image, so it follows the window's light or dark appearance.
  private static func image(of chord: String) -> NSImage {
    let font = NSFont.preferredFont(forTextStyle: .caption1)
    let measured = (chord as NSString).size(withAttributes: [.font: font])
    let size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
    let image = NSImage(size: size, flipped: false) { rect in
      (chord as NSString).draw(
        in: rect, withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
      return true
    }
    image.accessibilityDescription = chord
    return image
  }
}

private struct CommandKeyChordHintModifier: ViewModifier {
  let chord: String?
  let spacing: CGFloat
  @Environment(CommandKeyObserver.self) private var observer

  func body(content: Content) -> some View {
    HStack(spacing: spacing) {
      content
      if observer.isCommandHeld, let chord {
        ShortcutHintLabel(chord: chord, font: .callout)
      }
    }
  }
}

private struct CommandKeyHintModifier: ViewModifier {
  let id: CommandID
  let spacing: CGFloat
  @Environment(CommandKeyObserver.self) private var observer
  @Environment(\.resolvedShortcuts) private var shortcuts

  func body(content: Content) -> some View {
    HStack(spacing: spacing) {
      content
      if let chord = chordText {
        ShortcutHintLabel(chord: chord, font: .callout)
      }
    }
  }

  private var chordText: String? {
    guard observer.isCommandHeld else { return nil }
    return ShortcutDisplay.chord(for: id, in: shortcuts)
  }
}
