import Testing

@testable import TouchCode

/// Pins the public API contract for the Diff module. The defaults below
/// match the design doc's Public API section. Bumping any default here is
/// a public-surface change and almost certainly needs a bridge-protocol
/// version bump too.
@MainActor
struct DiffPublicTests {
  @Test
  func configurationDefaultsMatchDesign() {
    let config = DiffConfiguration()
    #expect(config.appearance == .automatic)
    #expect(config.style == .unified)
    #expect(config.indicators == .bars)
    #expect(config.showsLineNumbers == true)
    #expect(config.showsChangeBackgrounds == true)
    #expect(config.wrapsLines == false)
    #expect(config.showsFileHeaders == true)
    #expect(config.inlineChangeStyle == .wordAlt)
    #expect(config.allowsSelection == true)
  }

  @Test
  func diffFileIDFallsBackThroughOldThenEmpty() {
    let added = DiffFile(oldPath: nil, newPath: "a.swift", oldContents: "", newContents: "x")
    let deleted = DiffFile(oldPath: "b.swift", newPath: nil, oldContents: "y", newContents: "")
    let degenerate = DiffFile(oldPath: nil, newPath: nil, oldContents: "", newContents: "")
    #expect(added.id == "a.swift")
    #expect(deleted.id == "b.swift")
    #expect(degenerate.id == "")
  }

  @Test
  func diffDocumentInitDefaultsTitleAndFallbackPatchToNil() {
    let doc = DiffDocument(files: [])
    #expect(doc.files.isEmpty)
    #expect(doc.title == nil)
    #expect(doc.fallbackPatch == nil)
  }
}
