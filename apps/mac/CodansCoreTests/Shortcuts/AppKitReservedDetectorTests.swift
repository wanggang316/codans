import Foundation
import Testing

@testable import CodansCore

struct AppKitReservedDetectorTests {
  @Test
  func quitChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: KeyCode.ansiQ, modifiers: [.command]))
  }

  @Test
  func closeWindowChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: KeyCode.ansiW, modifiers: [.command]))
  }

  @Test
  func hideChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: KeyCode.ansiH, modifiers: [.command]))
  }

  @Test
  func minimizeChordIsReserved() {
    #expect(AppKitReservedDetector.isReserved(keyCode: KeyCode.ansiM, modifiers: [.command]))
  }

  @Test
  func settingsChordIsReserved() {
    #expect(
      AppKitReservedDetector.isReserved(keyCode: KeyCode.ansiComma, modifiers: [.command])
    )
  }

  @Test
  func helpChordIsReserved() {
    #expect(
      AppKitReservedDetector.isReserved(
        keyCode: KeyCode.ansiSlash,
        modifiers: [.command, .shift]
      )
    )
  }

  @Test
  func nonReservedChordIsNotReserved() {
    // ⌘T (new tab) — bound by codans, not by the standard AppKit menu.
    #expect(
      !AppKitReservedDetector.isReserved(keyCode: KeyCode.ansiT, modifiers: [.command])
    )
  }

  @Test
  func modifierOrderIsCanonicalized() {
    // OptionSet equality is order-independent; ⌘⇧? and ⇧⌘? must collapse to the same lookup.
    let asCommandShift = AppKitReservedDetector.isReserved(
      keyCode: KeyCode.ansiSlash,
      modifiers: [.command, .shift]
    )
    let asShiftCommand = AppKitReservedDetector.isReserved(
      keyCode: KeyCode.ansiSlash,
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
