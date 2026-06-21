import CoreText
import Foundation

/// Best-effort enumerator of monospaced font families installed on the system,
/// used to populate the Settings → Terminal font picker. libghostty exposes no
/// font-list API, so we go straight to Core Text and keep only families that
/// advertise the monospace trait — the sensible default surface for a terminal.
///
/// Never throws; on any failure it returns an empty list and the picker falls
/// back to "Default" plus whatever the user already has on disk. Ghostty does
/// its own Core Text discovery for `font-family`, so the family names we list
/// here resolve 1:1 when written to the config.
enum GhosttyFontCatalog {
  /// Monospaced font family names, de-duplicated and sorted for display.
  /// Hidden system families (those whose name starts with ".") are excluded.
  static func monospacedFamilies() -> [String] {
    let collection = CTFontCollectionCreateFromAvailableFonts(nil)
    guard
      let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection)
        as? [CTFontDescriptor]
    else { return [] }

    let monoMask = CTFontSymbolicTraits.traitMonoSpace.rawValue
    var families: Set<String> = []
    for descriptor in descriptors {
      guard
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
          as? [CFString: Any],
        let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value,
        symbolic & monoMask != 0,
        let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute)
          as? String,
        !family.hasPrefix(".")
      else { continue }
      families.insert(family)
    }
    return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }
}
