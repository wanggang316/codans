import Foundation
import Testing

@testable import CodansCore

/// Pins the named palette and its wire format.
///
/// The hex values are a design decision, not an implementation detail — a
/// typo in one would ship a slightly-wrong swatch that nobody notices by
/// reading the diff, so the table is asserted rather than trusted.
struct ProjectColorTests {
  /// Palette order matters: `namedCases` is the order the swatch row paints.
  @Test
  func namedPaletteIsTheDesignedSetInOrder() {
    #expect(
      ProjectColor.namedCases == [
        .blue, .purple, .pink, .red, .orange, .yellow, .green, .grey,
      ]
    )
  }

  @Test
  func namedPaletteHexValues() {
    let expected: [(ProjectColor, String)] = [
      (.blue, "#1594F9"),
      (.purple, "#A05EA3"),
      (.pink, "#F179AC"),
      (.red, "#DF6055"),
      (.orange, "#F29A46"),
      (.yellow, "#FCD05E"),
      (.green, "#84C068"),
      (.grey, "#A8A8A8"),
    ]
    for (color, hex) in expected {
      #expect(color.hexValue == hex, "\(color.displayName) should be \(hex)")
    }
  }

  /// Every named entry must parse, or `swiftUIColor` silently falls back to
  /// the system accent and the swatch paints the wrong color.
  @Test
  func everyNamedHexParses() {
    for color in ProjectColor.namedCases {
      #expect(ProjectColor.parseHex(color.hexValue) != nil, "\(color.displayName) hex is unparseable")
    }
  }

  @Test
  func everyNamedEntryHasADistinctHexAndName() {
    let hexes = Set(ProjectColor.namedCases.map(\.hexValue))
    let names = Set(ProjectColor.namedCases.map(\.displayName))
    #expect(hexes.count == ProjectColor.namedCases.count)
    #expect(names.count == ProjectColor.namedCases.count)
  }

  // MARK: - Codable

  /// The wire format is the lower-cased label. Repainting the palette must not
  /// disturb it: a catalog written before the colors changed still decodes to
  /// the same case, it just renders in the new hue.
  @Test
  func namedEntriesRoundTripAsTheirLowerCasedLabel() throws {
    for color in ProjectColor.namedCases {
      let data = try JSONEncoder().encode(color)
      let raw = String(data: data, encoding: .utf8)
      #expect(raw == "\"\(color.displayName.lowercased())\"")
      #expect(try JSONDecoder().decode(ProjectColor.self, from: data) == color)
    }
  }

  @Test
  func customHexRoundTripsUppercased() throws {
    let data = try JSONEncoder().encode(ProjectColor.custom(hex: "#ab12ef"))
    #expect(String(data: data, encoding: .utf8) == "\"#AB12EF\"")
    #expect(try JSONDecoder().decode(ProjectColor.self, from: data) == .custom(hex: "#AB12EF"))
  }

  @Test
  func unknownNameThrows() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ProjectColor.self, from: Data("\"chartreuse\"".utf8))
    }
  }

  /// `hexValue` is the single resolution path, so `.custom` has to route
  /// through it too rather than being special-cased at the call site.
  @Test
  func customExposesItsOwnHex() {
    #expect(ProjectColor.custom(hex: "#123456").hexValue == "#123456")
  }
}
