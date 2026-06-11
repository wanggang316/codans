import Carbon.HIToolbox
import Foundation
import Testing

@testable import CodansCore

struct AppKitReservedDetectorTests {
  @Test
  func quitChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command]))
  }

  @Test
  func closeWindowChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command]))
  }

  @Test
  func hideChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command]))
  }

  @Test
  func minimizeChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: UInt16(kVK_ANSI_M), modifiers: [.command]))
  }

  @Test
  func settingsChordIsReserved() {
    #expect(
      AppKitReservedDetector.isReserved(keyCode: UInt16(kVK_ANSI_Comma), modifiers: [.command])
    )
  }

  @Test
  func helpChordIsReserved() {
    #expect(
      AppKitReservedDetector.isReserved(
        keyCode: UInt16(kVK_ANSI_Slash),
        modifiers: [.command, .shift]
      )
    )
  }

  @Test
  func nonReservedChordIsNotReserved() {
    // ⌘T (new tab) — bound by codans, not by the standard AppKit menu.
    #expect(
      !AppKitReservedDetector.isReserved(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command])
    )
  }

  @Test
  func modifierOrderIsCanonicalized() {
    // OptionSet equality is order-independent; ⌘⇧? and ⇧⌘? must collapse to the same lookup.
    let asCommandShift = AppKitReservedDetector.isReserved(
      keyCode: UInt16(kVK_ANSI_Slash),
      modifiers: [.command, .shift]
    )
    let asShiftCommand = AppKitReservedDetector.isReserved(
      keyCode: UInt16(kVK_ANSI_Slash),
      modifiers: [.shift, .command]
    )
    #expect(asCommandShift == asShiftCommand)
    #expect(asShiftCommand)
  }

  @Test
  func reservedChordsHasExactlySixEntries() {
    #expect(AppKitReservedDetector.reservedChords.count == 6)
  }
}
