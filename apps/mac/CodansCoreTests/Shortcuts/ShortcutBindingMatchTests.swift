import Testing

@testable import CodansCore

struct ShortcutBindingMatchTests {
  private let optionOne = ShortcutBinding(keyCode: 0x12, modifiers: [.option])

  @Test
  func matchesSameKeyAndExactModifiers() {
    #expect(optionOne.matches(keyCode: 0x12, modifiers: [.option]))
  }

  @Test
  func rejectsOtherKeyOrExtraModifiers() {
    #expect(!optionOne.matches(keyCode: 0x13, modifiers: [.option]))
    #expect(!optionOne.matches(keyCode: 0x12, modifiers: [.option, .shift]))
    #expect(!optionOne.matches(keyCode: 0x12, modifiers: []))
  }

  @Test
  func disabledBindingMatchesNothing() {
    let disabled = ShortcutBinding(keyCode: 0x12, modifiers: [.option], isEnabled: false)
    #expect(!disabled.matches(keyCode: 0x12, modifiers: [.option]))
  }
}
