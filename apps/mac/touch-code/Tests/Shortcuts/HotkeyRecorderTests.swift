import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct HotkeyRecorderTests {
  @Test
  func validatorAcceptsCommandLetter() {
    let result = HotkeyRecorderNSView.validate(
      keyCode: UInt16(kVK_ANSI_T),
      flags: [.command]
    )
    switch result {
    case .success(let binding):
      #expect(binding.keyCode == UInt16(kVK_ANSI_T))
      #expect(binding.modifiers == [.command])
      #expect(binding.isEnabled == true)
    case .failure(let reason):
      Issue.record("Expected success, got rejection: \(reason)")
    }
  }

  @Test
  func validatorAcceptsCommandShiftLetter() {
    let result = HotkeyRecorderNSView.validate(
      keyCode: UInt16(kVK_ANSI_G),
      flags: [.command, .shift]
    )
    if case .success(let binding) = result {
      #expect(binding.modifiers == [.command, .shift])
    } else {
      Issue.record("Expected success.")
    }
  }

  @Test
  func validatorRejectsBareLetter() {
    let result = HotkeyRecorderNSView.validate(
      keyCode: UInt16(kVK_ANSI_A),
      flags: []
    )
    if case .failure(let reason) = result {
      #expect(reason == .missingPrimaryModifier)
    } else {
      Issue.record("Expected rejection.")
    }
  }

  @Test
  func validatorRejectsShiftOnly() {
    let result = HotkeyRecorderNSView.validate(
      keyCode: UInt16(kVK_ANSI_A),
      flags: [.shift]
    )
    if case .failure(let reason) = result {
      #expect(reason == .missingPrimaryModifier)
    } else {
      Issue.record("Expected rejection.")
    }
  }

  @Test
  func validatorRejectsModifierKeyCode() {
    // 0x37 is the kVK_Command keyCode — pressing ⌘ alone produces a keyDown with this code.
    let result = HotkeyRecorderNSView.validate(
      keyCode: 0x37,
      flags: [.command]
    )
    if case .failure(let reason) = result {
      #expect(reason == .modifierOnly)
    } else {
      Issue.record("Expected rejection.")
    }
  }

  @Test
  func capslockBitIsMasked() {
    var flags: NSEvent.ModifierFlags = [.command]
    flags.insert(.capsLock)
    let mask = ModifierMask(eventFlags: flags)
    #expect(mask == [.command])
  }

  @Test
  func arrowKeyIsAcceptedWithModifier() {
    let result = HotkeyRecorderNSView.validate(
      keyCode: UInt16(kVK_LeftArrow),
      flags: [.option]
    )
    if case .success(let binding) = result {
      #expect(binding.keyCode == UInt16(kVK_LeftArrow))
      #expect(binding.modifiers == [.option])
    } else {
      Issue.record("Expected success.")
    }
  }
}
