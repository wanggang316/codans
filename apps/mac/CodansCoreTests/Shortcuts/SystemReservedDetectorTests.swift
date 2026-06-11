import Foundation
import Testing

@testable import CodansCore

/// Each test owns a uniquely-named `UserDefaults` suite so cases can run in parallel without
/// stomping on each other's persistent domain. Suites are torn down at scope exit via
/// `removePersistentDomain(forName:)`.
private struct DefaultsSuite: ~Copyable {
  let name: String
  let defaults: UserDefaults

  init(label: String = #function) {
    let cleaned = label.replacingOccurrences(of: "(", with: "")
      .replacingOccurrences(of: ")", with: "")
    self.name = "com.gumpw.codans.tests.SystemReservedDetector.\(cleaned).\(UUID().uuidString)"
    self.defaults = UserDefaults(suiteName: name)!
  }

  func install(_ payload: [String: Any]) {
    defaults.setPersistentDomain(payload, forName: name)
  }

  deinit {
    defaults.removePersistentDomain(forName: name)
  }
}

/// `kVK_ANSI_Space` from `Carbon.HIToolbox` — duplicated here to keep the test target
/// AppKit/Carbon-free and aligned with the layout-independent storage convention.
private let kVKSpace: UInt16 = 49
private let kVKReturn: UInt16 = 36

private let cmdBit: Int = 1 << 20
private let optBit: Int = 1 << 19
private let ctrlBit: Int = 1 << 18
private let shiftBit: Int = 1 << 17
private let capsLockBit: Int = 1 << 16

private func entry(enabled: Bool, character: Int, keyCode: Int, flags: Int) -> [String: Any] {
  [
    "enabled": enabled,
    "value": [
      "type": "standard",
      "parameters": [character, keyCode, flags] as [Any],
    ] as [String: Any],
  ]
}

struct SystemReservedDetectorTests {
  @Test
  func emptyUserDefaultsHasNoReservedChords() {
    let suite = DefaultsSuite()
    suite.install([:])

    #expect(SystemReservedDetector.reservedChords(in: suite.defaults).isEmpty)
    #expect(
      SystemReservedDetector.isReserved(
        keyCode: kVKSpace,
        modifiers: .command,
        in: suite.defaults
      ) == false
    )
  }

  @Test
  func enabledSpotlightLikeEntryIsReported() {
    let suite = DefaultsSuite()
    suite.install([
      "AppleSymbolicHotKeys": [
        // Spotlight ID is 64 in modern macOS; the parser keys off enabled+parameters,
        // not the symbolic ID, so any string key works for the contract under test.
        "64": entry(enabled: true, character: 32, keyCode: Int(kVKSpace), flags: cmdBit),
      ] as [String: Any],
    ])

    #expect(
      SystemReservedDetector.isReserved(
        keyCode: kVKSpace,
        modifiers: .command,
        in: suite.defaults
      )
    )
    // Different modifiers on the same key code must not match.
    #expect(
      SystemReservedDetector.isReserved(
        keyCode: kVKSpace,
        modifiers: [.command, .shift],
        in: suite.defaults
      ) == false
    )
  }

  @Test
  func disabledEntryIsSkipped() {
    let suite = DefaultsSuite()
    suite.install([
      "AppleSymbolicHotKeys": [
        "64": entry(enabled: false, character: 32, keyCode: Int(kVKSpace), flags: cmdBit),
      ] as [String: Any],
    ])

    #expect(SystemReservedDetector.reservedChords(in: suite.defaults).isEmpty)
  }

  @Test
  func malformedEntriesAreSkippedWithoutCrashing() {
    let suite = DefaultsSuite()
    suite.install([
      "AppleSymbolicHotKeys": [
        // parameters too short → skip
        "1": [
          "enabled": true,
          "value": ["parameters": [32] as [Any]] as [String: Any],
        ] as [String: Any],
        // missing `value` → skip
        "2": ["enabled": true] as [String: Any],
        // entirely wrong shape → skip
        "3": "not-a-dictionary",
        // virtualKeyCode == 0xFFFF (sentinel "no keyboard chord") → skip
        "4": entry(enabled: true, character: 0, keyCode: 0xFFFF, flags: cmdBit),
        // valid Cmd-Return alongside the noise → must survive the walk
        "5": entry(enabled: true, character: 13, keyCode: Int(kVKReturn), flags: cmdBit),
      ] as [String: Any],
    ])

    let chords = SystemReservedDetector.reservedChords(in: suite.defaults)
    #expect(chords == [.init(keyCode: kVKReturn, modifiers: .command)])
  }

  @Test
  func negativeFlagsSentinelIsSkipped() {
    // `parameters[2] == -1` is a "no chord" marker the OS occasionally writes alongside
    // `enabled == false`. Defense-in-depth: even when paired with `enabled == true` the
    // detector must skip the entry rather than decoding the bit-pattern as
    // 0xFFFF…FFFF and reporting every modifier as set.
    let suite = DefaultsSuite()
    suite.install([
      "AppleSymbolicHotKeys": [
        "99": entry(enabled: true, character: 0, keyCode: Int(kVKSpace), flags: -1),
      ] as [String: Any],
    ])

    #expect(SystemReservedDetector.reservedChords(in: suite.defaults).isEmpty)
  }

  @Test
  func multipleModifierBitsDecodeIntoUnion() {
    let suite = DefaultsSuite()
    let optCmd = optBit | cmdBit
    suite.install([
      "AppleSymbolicHotKeys": [
        "118": entry(
          enabled: true,
          character: 0,
          keyCode: Int(kVKSpace),
          // Caps-lock bit set too — must be masked away.
          flags: optCmd | capsLockBit
        ),
      ] as [String: Any],
    ])

    #expect(
      SystemReservedDetector.isReserved(
        keyCode: kVKSpace,
        modifiers: [.option, .command],
        in: suite.defaults
      )
    )
    // Confirm shift/control are NOT decoded in.
    #expect(
      SystemReservedDetector.isReserved(
        keyCode: kVKSpace,
        modifiers: [.option, .command, .shift],
        in: suite.defaults
      ) == false
    )
  }

  @Test
  func allFourModifierBitsDecodeIndependently() {
    let suite = DefaultsSuite()
    suite.install([
      "AppleSymbolicHotKeys": [
        "10": entry(
          enabled: true,
          character: 0,
          keyCode: Int(kVKSpace),
          flags: shiftBit | ctrlBit | optBit | cmdBit
        ),
      ] as [String: Any],
    ])

    let chords = SystemReservedDetector.reservedChords(in: suite.defaults)
    #expect(
      chords == [
        .init(keyCode: kVKSpace, modifiers: [.shift, .control, .option, .command])
      ]
    )
  }
}
