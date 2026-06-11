import Carbon.HIToolbox
import SwiftUI
import CodansCore

/// Layout-aware display + SwiftUI binding helpers for `ShortcutBinding`.
///
/// Two lookup paths sit side-by-side:
///
/// - **Display** (`keycap(for:)`, `chord(for:)`) renders against the *active* keyboard
///   layout so a chord shows the keycap symbol that physically appears on the user's keys.
///   When the user switches input source, SwiftUI's view-update cycle re-reads the chord
///   strings on next render and the menu items pick up the new glyphs without explicit
///   invalidation.
/// - **Binding** (`keyEquivalent(for:)`) translates against the *ASCII-capable* keyboard
///   layout that macOS pairs with the active input source (typically
///   `com.apple.keylayout.US` for English / Pinyin / Hangul; the user's chosen ASCII layout
///   for Dvorak / UK English). SwiftUI's `.keyboardShortcut` matches against the *typed
///   character* the user produces, so binding to this layout keeps the chord stable when
///   the user is in a non-ASCII input source. Note: a Dvorak user binding `⌘P` will fire on
///   the Dvorak `P` position, not the QWERTY `P` position — accepting the user's chosen
///   ASCII layout as the canonical mapping.
public enum ShortcutDisplay {
  // MARK: - Display

  /// Returns the human-readable keycap glyph for `keyCode`, suitable for menu chord
  /// rendering. Uppercased when the layout produces a letter. Falls back to a hex stub
  /// (`<0x12>`) when no mapping is available — rare, but ensures the row never renders
  /// blank.
  public static func keycap(for keyCode: UInt16) -> String {
    if let fixed = fixedGlyph(for: keyCode) { return fixed }
    if let translated = translateToCharacter(keyCode: keyCode, source: .activeLayout) {
      return translated.uppercased()
    }
    if let fallback = translateToCharacter(keyCode: keyCode, source: .asciiCapable) {
      return fallback.uppercased()
    }
    return String(format: "<0x%02X>", keyCode)
  }

  /// Returns the full chord display: modifier glyphs in canonical `⌃⌥⇧⌘` order followed by
  /// the keycap. Matches macOS menu-bar conventions.
  public static func chord(for binding: ShortcutBinding) -> String {
    modifiersDisplay(binding.modifiers) + keycap(for: binding.keyCode)
  }

  /// Modifier-only glyph string in canonical macOS order.
  public static func modifiersDisplay(_ mask: ModifierMask) -> String {
    var result = ""
    if mask.contains(.control) { result += "\u{2303}" }  // ⌃
    if mask.contains(.option) { result += "\u{2325}" }  // ⌥
    if mask.contains(.shift) { result += "\u{21E7}" }  // ⇧
    if mask.contains(.command) { result += "\u{2318}" }  // ⌘
    return result
  }

  // MARK: - SwiftUI binding

  /// Returns the `KeyEquivalent` SwiftUI matches against. For arrow / Return / Tab / Esc /
  /// Space / function keys, returns the SwiftUI typed value. For character keys, runs
  /// UCKeyTranslate against the ASCII-capable layout so the binding fires consistently
  /// regardless of the user's current input source. Returns `nil` only when no mapping
  /// exists.
  public static func keyEquivalent(for keyCode: UInt16) -> KeyEquivalent? {
    if let special = specialKeyEquivalent(for: keyCode) { return special }
    if let translated = translateToCharacter(keyCode: keyCode, source: .asciiCapable),
      let first = translated.first
    {
      return KeyEquivalent(first)
    }
    return nil
  }

  /// Translates a `ModifierMask` to SwiftUI's `SwiftUI.EventModifiers`.
  public static func eventModifiers(for mask: ModifierMask) -> SwiftUI.EventModifiers {
    var result: SwiftUI.EventModifiers = []
    if mask.contains(.command) { result.insert(.command) }
    if mask.contains(.option) { result.insert(.option) }
    if mask.contains(.control) { result.insert(.control) }
    if mask.contains(.shift) { result.insert(.shift) }
    return result
  }

  // MARK: - Fixed glyphs (non-character keys)

  private static func fixedGlyph(for keyCode: UInt16) -> String? {
    switch Int(keyCode) {
    case kVK_Return: return "\u{21A9}"  // ↩
    case kVK_Tab: return "\u{21E5}"  // ⇥
    case kVK_Space: return "\u{2423}"  // ␣
    case kVK_Delete: return "\u{232B}"  // ⌫
    case kVK_ForwardDelete: return "\u{2326}"  // ⌦
    case kVK_Escape: return "\u{238B}"  // ⎋
    case kVK_LeftArrow: return "\u{2190}"  // ←
    case kVK_RightArrow: return "\u{2192}"  // →
    case kVK_UpArrow: return "\u{2191}"  // ↑
    case kVK_DownArrow: return "\u{2193}"  // ↓
    case kVK_Home: return "\u{2196}"  // ↖
    case kVK_End: return "\u{2198}"  // ↘
    case kVK_PageUp: return "\u{21DE}"  // ⇞
    case kVK_PageDown: return "\u{21DF}"  // ⇟
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default: return nil
    }
  }

  private static func specialKeyEquivalent(for keyCode: UInt16) -> KeyEquivalent? {
    switch Int(keyCode) {
    case kVK_Return: return .return
    case kVK_Tab: return .tab
    case kVK_Space: return .space
    case kVK_Delete: return .delete
    case kVK_ForwardDelete: return .deleteForward
    case kVK_Escape: return .escape
    case kVK_LeftArrow: return .leftArrow
    case kVK_RightArrow: return .rightArrow
    case kVK_UpArrow: return .upArrow
    case kVK_DownArrow: return .downArrow
    case kVK_Home: return .home
    case kVK_End: return .end
    case kVK_PageUp: return .pageUp
    case kVK_PageDown: return .pageDown
    default: return nil
    }
  }

  // MARK: - UCKeyTranslate

  private enum LayoutSource {
    case activeLayout
    case asciiCapable
  }

  private static func translateToCharacter(keyCode: UInt16, source: LayoutSource) -> String? {
    let inputSourceRef: TISInputSource? = {
      switch source {
      case .activeLayout:
        return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
      case .asciiCapable:
        return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
      }
    }()
    guard let inputSource = inputSourceRef else { return nil }

    guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
      return nil
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
    let dataPtr = CFDataGetBytePtr(layoutData)
    guard let dataPtr else { return nil }

    return dataPtr.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layoutPtr -> String? in
      var deadKeyState: UInt32 = 0
      var actualLength: Int = 0
      var unicodeBuffer: [UniChar] = Array(repeating: 0, count: 4)
      let status = UCKeyTranslate(
        layoutPtr,
        keyCode,
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysMask),
        &deadKeyState,
        unicodeBuffer.count,
        &actualLength,
        &unicodeBuffer
      )
      guard status == noErr, actualLength > 0 else { return nil }
      let chars = unicodeBuffer.prefix(actualLength)
      let string = String(utf16CodeUnits: Array(chars), count: chars.count)
      // Filter out non-printable (e.g. NUL for unmapped keyCodes).
      let printable = string.unicodeScalars.allSatisfy { scalar in
        scalar.value >= 0x20 && scalar.value != 0x7F
      }
      return printable ? string : nil
    }
  }
}
