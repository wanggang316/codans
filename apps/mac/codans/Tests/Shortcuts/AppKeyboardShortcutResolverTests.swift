import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
import CodansCore

@testable import Codans

@MainActor
struct AppKeyboardShortcutResolverTests {
  @Test
  func resolvesActiveBindingFromMap() {
    let map = ShortcutResolver.resolve(overrides: .empty)
    let binding = AppKeyboardShortcutResolver.resolve(.commandPaletteToggle, in: map)
    #expect(binding?.key == KeyEquivalent("p"))
    #expect(binding?.modifiers == [.command])
  }

  @Test
  func disabledRowReturnsNil() {
    let disabled = ShortcutBinding(
      keyCode: UInt16(kVK_ANSI_G),
      modifiers: [.command, .shift],
      isEnabled: false
    )
    let store = ShortcutOverrideStore(overrides: [.toggleDiffInspector: disabled])
    let map = ShortcutResolver.resolve(overrides: store)
    #expect(AppKeyboardShortcutResolver.resolve(.toggleDiffInspector, in: map) == nil)
  }

  @Test
  func emptyMapReturnsNil() {
    let map: ResolvedShortcutMap = [:]
    #expect(AppKeyboardShortcutResolver.resolve(.newTab, in: map) == nil)
  }

  @Test
  func userOverrideReplacesDefault() {
    let custom = ShortcutBinding(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .control])
    let store = ShortcutOverrideStore(overrides: [.newTab: custom])
    let map = ShortcutResolver.resolve(overrides: store)
    let binding = AppKeyboardShortcutResolver.resolve(.newTab, in: map)
    #expect(binding?.key == KeyEquivalent("t"))
    #expect(binding?.modifiers == [.command, .control])
  }
}
