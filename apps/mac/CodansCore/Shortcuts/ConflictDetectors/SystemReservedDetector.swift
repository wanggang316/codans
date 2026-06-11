import Foundation

/// Detects chords reserved by macOS itself (Spotlight, Mission Control, input-source switch,
/// etc.) by parsing `com.apple.symbolichotkeys / AppleSymbolicHotKeys` from the supplied
/// `UserDefaults`.
///
/// Production callers pass `UserDefaults(suiteName: "com.apple.symbolichotkeys")`; tests pass
/// a hand-crafted suite. Keeping the source as an injected dependency keeps this type pure
/// and AppKit-free, matching the CodansCore boundary.
///
/// Plist shape (reverse-engineered, stable across modern macOS):
///
/// - Top-level dict keyed by stringified symbolic-hotkey integer ID.
/// - Each value is a dict with `enabled: Bool` and a nested `value` dict.
/// - `value.parameters` is `[character, virtualKeyCode, modifierFlagsRaw]` for keyboard
///   chords; non-keyboard hotkeys carry an empty / shorter array and are skipped.
///
/// `modifierFlagsRaw` mirrors `NSEvent.ModifierFlags`. We translate by bit position rather
/// than importing AppKit so the parser remains usable from frameworks that must not link
/// AppKit. Bits handled: shift `1<<17`, control `1<<18`, option `1<<19`, command `1<<20`.
/// All other bits (notably caps-lock `1<<16`) are ignored.
///
/// Parsing is intentionally lenient: any structural surprise yields an empty set instead of
/// a crash, so a future macOS plist schema bump degrades to "no system chords detected"
/// rather than blocking the recorder.
public enum SystemReservedDetector {
  public struct ReservedChord: Hashable, Sendable {
    public let keyCode: UInt16
    public let modifiers: ModifierMask

    public init(keyCode: UInt16, modifiers: ModifierMask) {
      self.keyCode = keyCode
      self.modifiers = modifiers
    }
  }

  /// Returns `true` if the supplied chord matches any enabled symbolic hotkey in `defaults`.
  public static func isReserved(
    keyCode: UInt16,
    modifiers: ModifierMask,
    in defaults: UserDefaults
  ) -> Bool {
    reservedChords(in: defaults).contains(ReservedChord(keyCode: keyCode, modifiers: modifiers))
  }

  /// Parses `AppleSymbolicHotKeys` and returns every `(keyCode, modifiers)` pair currently
  /// owned by the OS. Returns the empty set if the key is missing or the structure is
  /// unexpected.
  public static func reservedChords(in defaults: UserDefaults) -> Set<ReservedChord> {
    let snapshot = defaults.dictionaryRepresentation()
    guard let raw = snapshot["AppleSymbolicHotKeys"] as? [String: Any] else {
      return []
    }

    var chords: Set<ReservedChord> = []
    for (_, entry) in raw {
      guard let chord = parseEntry(entry) else { continue }
      chords.insert(chord)
    }
    return chords
  }

  // MARK: - Plist walk

  private static func parseEntry(_ entry: Any) -> ReservedChord? {
    guard let dict = entry as? [String: Any] else { return nil }
    guard let enabled = dict["enabled"] as? Bool, enabled else { return nil }
    guard let valueDict = dict["value"] as? [String: Any] else { return nil }
    guard let parameters = valueDict["parameters"] as? [Any], parameters.count >= 3 else {
      return nil
    }

    // parameters[0] is the unicode character — irrelevant for layout-independent storage.
    guard let keyCodeInt = intValue(parameters[1]) else { return nil }
    guard keyCodeInt >= 0, keyCodeInt < 0xFFFF else { return nil }
    guard let flagsInt = intValue(parameters[2]) else { return nil }
    // Negative flag values surface in the plist as "no chord" markers (paired with
    // `enabled == false` in practice). Reject them defensively so the bit-reinterpret
    // below doesn't light up every modifier on a sentinel.
    guard flagsInt >= 0 else { return nil }

    let keyCode = UInt16(keyCodeInt)
    let modifiers = decodeModifiers(rawFlags: UInt(flagsInt))
    return ReservedChord(keyCode: keyCode, modifiers: modifiers)
  }

  /// Plist numeric values can decode as `Int`, `NSNumber`, `Double`, or `Bool` depending on
  /// who wrote them. Coerce defensively without crashing on type drift.
  private static func intValue(_ any: Any) -> Int? {
    if let n = any as? Int { return n }
    if let n = any as? NSNumber { return n.intValue }
    if let n = any as? Double { return Int(n) }
    return nil
  }

  /// `NSEvent.ModifierFlags`-style bit positions. Keep this table local rather than
  /// importing AppKit so CodansCore stays UI-framework-free.
  private static func decodeModifiers(rawFlags: UInt) -> ModifierMask {
    var mask = ModifierMask()
    if rawFlags & (1 << 17) != 0 { mask.insert(.shift) }
    if rawFlags & (1 << 18) != 0 { mask.insert(.control) }
    if rawFlags & (1 << 19) != 0 { mask.insert(.option) }
    if rawFlags & (1 << 20) != 0 { mask.insert(.command) }
    return mask
  }
}
