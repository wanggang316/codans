import CoreText
import Foundation

/// All font families installed on the system, with the subset that advertises
/// the monospace trait flagged separately. The Settings → Terminal font picker
/// lists every family (Ghostty accepts any `font-family`) and badges the
/// monospaced ones, which are the sensible default for a terminal.
nonisolated struct GhosttyFontFamilies: Equatable, Sendable {
  /// Every family name, de-duplicated and sorted for display.
  let all: [String]
  /// Names within `all` that carry the Core Text monospace trait.
  let monospaced: Set<String>

  static let empty = GhosttyFontFamilies(all: [], monospaced: [])
}

/// Best-effort enumerator of installed font families via Core Text. libghostty
/// exposes no font-list API, so we go straight to Core Text. Never throws; on
/// any failure it returns `.empty` and the picker falls back to "Default" plus
/// whatever the user already has on disk. Ghostty does its own Core Text
/// discovery for `font-family`, so the family names we list resolve 1:1 when
/// written to the config.
enum GhosttyFontCatalog {
  /// Enumerate every installed family and flag the monospaced ones. Hidden
  /// system families (those whose name starts with ".") are excluded.
  static func families() -> GhosttyFontFamilies {
    let collection = CTFontCollectionCreateFromAvailableFonts(nil)
    guard
      let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection)
        as? [CTFontDescriptor]
    else { return .empty }

    let monoMask = CTFontSymbolicTraits.traitMonoSpace.rawValue
    var all: Set<String> = []
    var monospaced: Set<String> = []
    for descriptor in descriptors {
      guard
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute)
          as? String,
        !family.hasPrefix(".")
      else { continue }
      all.insert(family)

      if let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
        as? [CFString: Any],
        let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value,
        symbolic & monoMask != 0
      {
        monospaced.insert(family)
      }
    }
    return GhosttyFontFamilies(
      all: all.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
      monospaced: monospaced
    )
  }
}
