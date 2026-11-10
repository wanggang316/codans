import Carbon.HIToolbox
import Testing

@testable import CodansCore

/// `KeyCode` restates Carbon's virtual key codes so CodansCore builds for iOS. Persisted
/// shortcut overrides store the raw numbers, so any drift would silently rebind users' chords;
/// this pins every entry to its Carbon source of truth (the test target is macOS-only).
@Suite("KeyCode ↔ Carbon parity")
struct KeyCodeCarbonParityTests {
  private static let pairs: [(name: String, core: UInt16, carbon: Int)] = [
    ("ansiA", KeyCode.ansiA, kVK_ANSI_A),
    ("ansiS", KeyCode.ansiS, kVK_ANSI_S),
    ("ansiD", KeyCode.ansiD, kVK_ANSI_D),
    ("ansiF", KeyCode.ansiF, kVK_ANSI_F),
    ("ansiH", KeyCode.ansiH, kVK_ANSI_H),
    ("ansiG", KeyCode.ansiG, kVK_ANSI_G),
    ("ansiZ", KeyCode.ansiZ, kVK_ANSI_Z),
    ("ansiX", KeyCode.ansiX, kVK_ANSI_X),
    ("ansiC", KeyCode.ansiC, kVK_ANSI_C),
    ("ansiV", KeyCode.ansiV, kVK_ANSI_V),
    ("ansiB", KeyCode.ansiB, kVK_ANSI_B),
    ("ansiQ", KeyCode.ansiQ, kVK_ANSI_Q),
    ("ansiW", KeyCode.ansiW, kVK_ANSI_W),
    ("ansiE", KeyCode.ansiE, kVK_ANSI_E),
    ("ansiR", KeyCode.ansiR, kVK_ANSI_R),
    ("ansiY", KeyCode.ansiY, kVK_ANSI_Y),
    ("ansiT", KeyCode.ansiT, kVK_ANSI_T),
    ("ansiO", KeyCode.ansiO, kVK_ANSI_O),
    ("ansiU", KeyCode.ansiU, kVK_ANSI_U),
    ("ansiI", KeyCode.ansiI, kVK_ANSI_I),
    ("ansiP", KeyCode.ansiP, kVK_ANSI_P),
    ("ansiL", KeyCode.ansiL, kVK_ANSI_L),
    ("ansiJ", KeyCode.ansiJ, kVK_ANSI_J),
    ("ansiK", KeyCode.ansiK, kVK_ANSI_K),
    ("ansiN", KeyCode.ansiN, kVK_ANSI_N),
    ("ansiM", KeyCode.ansiM, kVK_ANSI_M),
    ("ansi1", KeyCode.ansi1, kVK_ANSI_1),
    ("ansi2", KeyCode.ansi2, kVK_ANSI_2),
    ("ansi3", KeyCode.ansi3, kVK_ANSI_3),
    ("ansi4", KeyCode.ansi4, kVK_ANSI_4),
    ("ansi5", KeyCode.ansi5, kVK_ANSI_5),
    ("ansi6", KeyCode.ansi6, kVK_ANSI_6),
    ("ansi7", KeyCode.ansi7, kVK_ANSI_7),
    ("ansi8", KeyCode.ansi8, kVK_ANSI_8),
    ("ansi9", KeyCode.ansi9, kVK_ANSI_9),
    ("ansi0", KeyCode.ansi0, kVK_ANSI_0),
    ("ansiEqual", KeyCode.ansiEqual, kVK_ANSI_Equal),
    ("ansiMinus", KeyCode.ansiMinus, kVK_ANSI_Minus),
    ("ansiRightBracket", KeyCode.ansiRightBracket, kVK_ANSI_RightBracket),
    ("ansiLeftBracket", KeyCode.ansiLeftBracket, kVK_ANSI_LeftBracket),
    ("ansiQuote", KeyCode.ansiQuote, kVK_ANSI_Quote),
    ("ansiSemicolon", KeyCode.ansiSemicolon, kVK_ANSI_Semicolon),
    ("ansiBackslash", KeyCode.ansiBackslash, kVK_ANSI_Backslash),
    ("ansiComma", KeyCode.ansiComma, kVK_ANSI_Comma),
    ("ansiSlash", KeyCode.ansiSlash, kVK_ANSI_Slash),
    ("ansiPeriod", KeyCode.ansiPeriod, kVK_ANSI_Period),
    ("ansiGrave", KeyCode.ansiGrave, kVK_ANSI_Grave),
    ("return", KeyCode.return, kVK_Return),
    ("tab", KeyCode.tab, kVK_Tab),
    ("space", KeyCode.space, kVK_Space),
    ("delete", KeyCode.delete, kVK_Delete),
    ("escape", KeyCode.escape, kVK_Escape),
    ("home", KeyCode.home, kVK_Home),
    ("pageUp", KeyCode.pageUp, kVK_PageUp),
    ("forwardDelete", KeyCode.forwardDelete, kVK_ForwardDelete),
    ("end", KeyCode.end, kVK_End),
    ("pageDown", KeyCode.pageDown, kVK_PageDown),
    ("leftArrow", KeyCode.leftArrow, kVK_LeftArrow),
    ("rightArrow", KeyCode.rightArrow, kVK_RightArrow),
    ("downArrow", KeyCode.downArrow, kVK_DownArrow),
    ("upArrow", KeyCode.upArrow, kVK_UpArrow),
  ]

  @Test func everyKeyCodeMatchesCarbon() {
    for pair in Self.pairs {
      #expect(Int(pair.core) == pair.carbon, "KeyCode.\(pair.name) drifted from Carbon")
    }
  }
}
