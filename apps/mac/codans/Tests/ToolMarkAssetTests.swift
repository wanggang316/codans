import AppKit
import CodansCore
import Testing

@testable import Codans

@MainActor
struct ToolMarkAssetTests {
  /// A mark without its image set would draw as an empty box everywhere the
  /// catalog maps to it — catch a case added without its SVG.
  @Test
  func everyToolMarkShipsATemplateAsset() {
    for mark in ToolMark.allCases {
      let image = NSImage(named: mark.assetName)
      #expect(image != nil, "missing asset \(mark.assetName)")
      #expect(image?.isTemplate == true, "\(mark.assetName) must be template-rendered")
    }
  }

  @Test
  func tintedMenuImageIsNonTemplate() {
    let image = CommandIconImage.tinted(.mark(.npm), color: .systemGreen)
    #expect(image?.isTemplate == false)
    #expect(CommandIconImage.tinted(.symbol("hammer.fill"), color: .systemGreen) != nil)
  }
}

@MainActor
struct GlobalCommandSuggestionSymbolTests {
  /// Curated suggestions name SF Symbols directly; a typo would draw nothing.
  @Test
  func everySuggestedSymbolExists() {
    for suggestion in GlobalCommandSuggestions.groups.flatMap(\.suggestions) {
      guard case .symbol(let name) = suggestion.icon else { continue }
      #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
    }
  }
}
