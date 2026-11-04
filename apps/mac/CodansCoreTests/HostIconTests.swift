import Foundation
import Testing

@testable import CodansCore

/// `HostRecord.icon` codec and the This Mac model mapping.
struct HostIconTests {
  /// Decodes an encoded `HostRecord(address: "box")` with `icon` set to
  /// `rawIcon` (no key for `nil`).
  private func decode(rawIcon: String?) throws -> HostRecord {
    var object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(HostRecord(address: "box"))) as? [String: Any])
    object["icon"] = rawIcon
    return try JSONDecoder().decode(HostRecord.self, from: JSONSerialization.data(withJSONObject: object))
  }

  @Test
  func missingIconDecodesAsNoIcon() throws {
    let record = try decode(rawIcon: nil)
    #expect(record.icon == nil)
    #expect(record.displayIcon == .server)
  }

  @Test(arguments: HostIcon.allCases)
  func knownIconRoundTrips(icon: HostIcon) throws {
    let record = HostRecord(address: "box", icon: icon)
    let data = try JSONEncoder().encode(record)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["icon"] as? String == icon.rawValue)
    #expect(try JSONDecoder().decode(HostRecord.self, from: data) == record)
  }

  @Test
  func unknownIconDecodesAsNoIcon() throws {
    let record = try decode(rawIcon: "toaster")
    #expect(record.icon == nil)
    #expect(record.address == "box")
  }

  @Test
  func validatedKeepsIcon() throws {
    #expect(try HostRecord(address: " box ", icon: .cloud).validated().icon == .cloud)
  }

  @Test
  func iconsAreOfferedInOrder() {
    #expect(
      HostIcon.allCases.map(\.displayName) == [
        "Globe", "Server", "Cloud", "MacBook", "Mac mini", "Mac Studio", "Desktop",
      ])
    #expect(
      HostIcon.allCases.map(\.systemImage) == [
        "globe", "server.rack", "icloud", "laptopcomputer", "macmini", "macstudio", "desktopcomputer",
      ])
  }

  @Test(arguments: [
    ("MacBook Pro (14-inch, 2023)", HostIcon.macBook),
    ("MacBook Air (M2, 2022)", .macBook),
    ("MacBookPro16,1", .macBook),
    ("Mac mini (2024)", .macMini),
    ("Macmini8,1", .macMini),
    ("Mac Studio (2023)", .macStudio),
    ("iMac (24-inch, 2023)", .desktop),
    ("Mac Pro (2023)", .desktop),
    ("Mac16,10", .desktop),
    ("", .desktop),
  ])
  func macModelMapsToIcon(model: String, expected: HostIcon) {
    #expect(HostIcon.forMacModel(model) == expected)
  }
}
