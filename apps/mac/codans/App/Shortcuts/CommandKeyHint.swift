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
  /// place: the glyph shrinks, blurs, and fades out (`shortcutHintOutgoing(_:)`) and the
  /// chord fades in, centered on it. The label is as wide as the chord while it shows.
  /// Apply it on the *label* of a Button / Menu, like `commandKeyHint(_:spacing:)`.
  func commandKeyHintReplacing(_ id: CommandID) -> some View {
    modifier(CommandKeyHintReplacingModifier(id: id))
  }
}

private struct CommandKeyHintReplacingModifier: ViewModifier {
  let id: CommandID
  @Environment(CommandKeyObserver.self) private var observer
  @Environment(\.resolvedShortcuts) private var shortcuts

  func body(content: Content) -> some View {
    let chord = observer.isCommandHeld ? ShortcutDisplay.chord(for: id, in: shortcuts) : nil
    ZStack {
      content
        .shortcutHintOutgoing(chord != nil)
      if let chord {
        ShortcutHintLabel(chord: chord, font: .callout)
      }
    }
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
