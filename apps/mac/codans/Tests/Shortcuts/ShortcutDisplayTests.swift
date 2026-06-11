import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
import CodansCore

@testable import Codans

@MainActor
struct ShortcutDisplayTests {
  // MARK: - Modifier glyphs

  @Test
  func modifierGlyphsAppearInCanonicalOrder() {
    #expect(ShortcutDisplay.modifiersDisplay([.command]) == "\u{2318}")
    #expect(ShortcutDisplay.modifiersDisplay([.command, .shift]) == "\u{21E7}\u{2318}")
    #expect(ShortcutDisplay.modifiersDisplay([.command, .option]) == "\u{2325}\u{2318}")
    // Canonical order is ⌃⌥⇧⌘ regardless of insertion order.
    #expect(
      ShortcutDisplay.modifiersDisplay([.command, .control, .option, .shift])
        == "\u{2303}\u{2325}\u{21E7}\u{2318}"
    )
  }

  // MARK: - Fixed glyphs (non-character keys)

  @Test
  func arrowAndReturnKeysRenderAsSymbols() {
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_UpArrow)) == "\u{2191}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_DownArrow)) == "\u{2193}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_LeftArrow)) == "\u{2190}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_RightArrow)) == "\u{2192}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_Return)) == "\u{21A9}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_Escape)) == "\u{238B}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_Tab)) == "\u{21E5}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_Space)) == "\u{2423}")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_Delete)) == "\u{232B}")
  }

  @Test
  func functionKeysRenderAsLabels() {
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_F1)) == "F1")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_F12)) == "F12")
  }

  // MARK: - Character keys (ASCII-capable layout fallback)

  @Test
  func letterKeysRenderUppercase() {
    // Smoke test: on any reasonable test runner the ASCII-capable layout fallback returns
    // the U.S. character for ANSI keyCodes. The active layout may match too.
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_ANSI_G)) == "G")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_ANSI_P)) == "P")
  }

  @Test
  func bracketsAndCommaRender() {
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_ANSI_LeftBracket)) == "[")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_ANSI_RightBracket)) == "]")
    #expect(ShortcutDisplay.keycap(for: UInt16(kVK_ANSI_Comma)) == ",")
  }

  @Test
  func unmappedKeyCodeFallsBackToHexStub() {
    let result = ShortcutDisplay.keycap(for: UInt16(0xFF))
    // 0xFF is a sentinel-like keyCode that shouldn't translate.
    #expect(result.hasPrefix("<0x") || result.count == 1, "Unexpected fallback shape: \(result)")
  }

  // MARK: - chord(for:)

  @Test
  func chordCombinesModifiersAndKeycap() {
    let binding = ShortcutBinding(
      keyCode: UInt16(kVK_ANSI_G),
      modifiers: [.command, .shift]
    )
    #expect(ShortcutDisplay.chord(for: binding) == "\u{21E7}\u{2318}G")
  }

  @Test
  func chordWithFunctionKey() {
    let binding = ShortcutBinding(
      keyCode: UInt16(kVK_F5),
      modifiers: [.option, .control]
    )
    #expect(ShortcutDisplay.chord(for: binding) == "\u{2303}\u{2325}F5")
  }

  // MARK: - keyEquivalent(for:)

  @Test
  func arrowKeyEquivalentsAreSwiftUITypedValues() {
    #expect(ShortcutDisplay.keyEquivalent(for: UInt16(kVK_UpArrow)) == .upArrow)
    #expect(ShortcutDisplay.keyEquivalent(for: UInt16(kVK_Return)) == .return)
    #expect(ShortcutDisplay.keyEquivalent(for: UInt16(kVK_Escape)) == .escape)
    #expect(ShortcutDisplay.keyEquivalent(for: UInt16(kVK_Tab)) == .tab)
  }

  @Test
  func letterKeyEquivalentsAreLowercaseCharacter() {
    // SwiftUI's `KeyEquivalent` matches against typed character; UCKeyTranslate against
    // the ASCII-capable layout produces lowercase letters by default.
    #expect(ShortcutDisplay.keyEquivalent(for: UInt16(kVK_ANSI_G)) == KeyEquivalent("g"))
    #expect(ShortcutDisplay.keyEquivalent(for: UInt16(kVK_ANSI_P)) == KeyEquivalent("p"))
  }

  // MARK: - eventModifiers(for:)

  @Test
  func eventModifiersTranslatesEachFlag() {
    #expect(ShortcutDisplay.eventModifiers(for: [.command]) == [.command])
    #expect(ShortcutDisplay.eventModifiers(for: [.command, .shift]) == [.command, .shift])
    #expect(
      ShortcutDisplay.eventModifiers(for: [.command, .option, .control, .shift])
        == [.command, .option, .control, .shift]
    )
    #expect(ShortcutDisplay.eventModifiers(for: []) == [])
  }
}
