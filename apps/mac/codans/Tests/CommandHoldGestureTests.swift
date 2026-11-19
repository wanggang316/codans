import AppKit
import Testing

@testable import Codans

/// Shortcut hints show only for a hold of ⌘ alone. Any other key or modifier during the
/// press ends the hold until ⌘ goes up.
@MainActor
struct CommandHoldGestureTests {
  @Test func commandAloneIsAHold() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command])
    #expect(gesture.isHolding)
  }

  @Test func releasingCommandEndsTheHold() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command])
    gesture.modifiersChanged([])
    #expect(!gesture.isHolding)
  }

  @Test func keyPressEndsTheHoldUntilCommandGoesUp() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command])
    gesture.keyPressed()
    #expect(!gesture.isHolding)

    // ⌘ stays down after the chord: still no hold.
    gesture.modifiersChanged([.command])
    #expect(!gesture.isHolding)

    gesture.modifiersChanged([])
    gesture.modifiersChanged([.command])
    #expect(gesture.isHolding)
  }

  @Test func otherModifierEndsTheHoldUntilCommandGoesUp() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command])
    gesture.modifiersChanged([.command, .shift])
    #expect(!gesture.isHolding)

    gesture.modifiersChanged([.command])
    #expect(!gesture.isHolding)
  }

  @Test func commandAddedToAnotherModifierIsNotAHold() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.option])
    gesture.modifiersChanged([.option, .command])
    #expect(!gesture.isHolding)

    gesture.modifiersChanged([.command])
    #expect(!gesture.isHolding)
  }

  @Test func capsLockDoesNotAffectTheHold() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command, .capsLock])
    #expect(gesture.isHolding)
  }

  @Test func keyPressWithoutCommandDoesNothing() {
    var gesture = CommandHoldGesture()
    gesture.keyPressed()
    gesture.modifiersChanged([.command])
    #expect(gesture.isHolding)
  }

  @Test func resetEndsTheHold() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command])
    gesture.keyPressed()
    gesture.reset()
    gesture.modifiersChanged([.command])
    #expect(gesture.isHolding)
  }

  // MARK: - Hold of ⌘⌥ (Pane number hint)

  @Test(arguments: [
    [NSEvent.ModifierFlags.command, [.command, .option]],
    [NSEvent.ModifierFlags.option, [.command, .option]],
  ])
  func commandOptionInEitherOrderIsAHold(steps: [NSEvent.ModifierFlags]) {
    var gesture = CommandHoldGesture(modifiers: [.command, .option])
    gesture.modifiersChanged(steps[0])
    #expect(!gesture.isHolding)
    gesture.modifiersChanged(steps[1])
    #expect(gesture.isHolding)
  }

  @Test func releasingEitherKeyEndsTheCommandOptionHold() {
    for remaining: NSEvent.ModifierFlags in [.command, .option] {
      var gesture = CommandHoldGesture(modifiers: [.command, .option])
      gesture.modifiersChanged([.command, .option])
      gesture.modifiersChanged(remaining)
      #expect(!gesture.isHolding)
      // Pressing the released key again is a new hold.
      gesture.modifiersChanged([.command, .option])
      #expect(gesture.isHolding)
    }
  }

  @Test func extraModifierIsNotACommandOptionHold() {
    var gesture = CommandHoldGesture(modifiers: [.command, .option])
    gesture.modifiersChanged([.command, .option, .shift])
    #expect(!gesture.isHolding)
    gesture.modifiersChanged([.command, .option])
    #expect(!gesture.isHolding)
  }

  @Test func commandOptionHoldIsAChordForTheCommandHold() {
    var gesture = CommandHoldGesture()
    gesture.modifiersChanged([.command])
    gesture.modifiersChanged([.command, .option])
    #expect(!gesture.isHolding)
  }
}
