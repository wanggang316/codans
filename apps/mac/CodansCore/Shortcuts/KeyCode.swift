/// Virtual key codes for the physical keys CodansCore references, in the same numeric space
/// as `Carbon.HIToolbox.kVK_*` and `NSEvent.keyCode`.
///
/// CodansCore is shared with the iOS companion, where Carbon does not exist, so the values are
/// restated here instead of imported. They must never drift from Carbon: persisted
/// `shortcuts.json` overrides store these raw numbers. `KeyCodeCarbonParityTests` pins every
/// entry against the Carbon constant on macOS.
public enum KeyCode {
  // MARK: Letters (ANSI layout positions)

  public static let ansiA: UInt16 = 0x00
  public static let ansiS: UInt16 = 0x01
  public static let ansiD: UInt16 = 0x02
  public static let ansiF: UInt16 = 0x03
  public static let ansiH: UInt16 = 0x04
  public static let ansiG: UInt16 = 0x05
  public static let ansiZ: UInt16 = 0x06
  public static let ansiX: UInt16 = 0x07
  public static let ansiC: UInt16 = 0x08
  public static let ansiV: UInt16 = 0x09
  public static let ansiB: UInt16 = 0x0B
  public static let ansiQ: UInt16 = 0x0C
  public static let ansiW: UInt16 = 0x0D
  public static let ansiE: UInt16 = 0x0E
  public static let ansiR: UInt16 = 0x0F
  public static let ansiY: UInt16 = 0x10
  public static let ansiT: UInt16 = 0x11
  public static let ansiO: UInt16 = 0x1F
  public static let ansiU: UInt16 = 0x20
  public static let ansiI: UInt16 = 0x22
  public static let ansiP: UInt16 = 0x23
  public static let ansiL: UInt16 = 0x25
  public static let ansiJ: UInt16 = 0x26
  public static let ansiK: UInt16 = 0x28
  public static let ansiN: UInt16 = 0x2D
  public static let ansiM: UInt16 = 0x2E

  // MARK: Digits (note the non-monotonic 5/6 and 7/8/9 ordering)

  public static let ansi1: UInt16 = 0x12
  public static let ansi2: UInt16 = 0x13
  public static let ansi3: UInt16 = 0x14
  public static let ansi4: UInt16 = 0x15
  public static let ansi6: UInt16 = 0x16
  public static let ansi5: UInt16 = 0x17
  public static let ansi9: UInt16 = 0x19
  public static let ansi7: UInt16 = 0x1A
  public static let ansi8: UInt16 = 0x1C
  public static let ansi0: UInt16 = 0x1D

  // MARK: Punctuation

  public static let ansiEqual: UInt16 = 0x18
  public static let ansiMinus: UInt16 = 0x1B
  public static let ansiRightBracket: UInt16 = 0x1E
  public static let ansiLeftBracket: UInt16 = 0x21
  public static let ansiQuote: UInt16 = 0x27
  public static let ansiSemicolon: UInt16 = 0x29
  public static let ansiBackslash: UInt16 = 0x2A
  public static let ansiComma: UInt16 = 0x2B
  public static let ansiSlash: UInt16 = 0x2C
  public static let ansiPeriod: UInt16 = 0x2F
  public static let ansiGrave: UInt16 = 0x32

  // MARK: Layout-independent keys

  public static let `return`: UInt16 = 0x24
  public static let tab: UInt16 = 0x30
  public static let space: UInt16 = 0x31
  public static let delete: UInt16 = 0x33
  public static let escape: UInt16 = 0x35
  public static let home: UInt16 = 0x73
  public static let pageUp: UInt16 = 0x74
  public static let forwardDelete: UInt16 = 0x75
  public static let end: UInt16 = 0x77
  public static let pageDown: UInt16 = 0x79
  public static let leftArrow: UInt16 = 0x7B
  public static let rightArrow: UInt16 = 0x7C
  public static let downArrow: UInt16 = 0x7D
  public static let upArrow: UInt16 = 0x7E
}
