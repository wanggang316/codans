import Foundation
import Testing

@testable import CodansCore

/// Exercises `ProjectIcon`'s wire shape and its tint rule.
///
/// The wire shape is prefix-tagged (`sf:` / `file:`) so the two cases can
/// never be confused for one another, and so a value written by a future
/// build lands in the "unknown" branch rather than being mis-read as a
/// symbol name.
struct ProjectIconTests {
  // MARK: - Codable

  @Test
  func symbolRoundTrips() throws {
    let icon = ProjectIcon.symbol("terminal")
    let data = try JSONEncoder().encode(icon)
    #expect(String(data: data, encoding: .utf8) == "\"sf:terminal\"")
    #expect(try JSONDecoder().decode(ProjectIcon.self, from: data) == icon)
  }

  @Test
  func customRoundTrips() throws {
    let icon = ProjectIcon.custom(fileName: "ABC123.svg")
    let data = try JSONEncoder().encode(icon)
    #expect(String(data: data, encoding: .utf8) == "\"file:ABC123.svg\"")
    #expect(try JSONDecoder().decode(ProjectIcon.self, from: data) == icon)
  }

  @Test
  func symbolNameKeepsDotsAndColons() throws {
    // Only the FIRST `sf:` is the tag — a symbol name containing a colon must
    // survive intact rather than being split again.
    let icon = ProjectIcon.symbol("folder.fill.badge.plus")
    let data = try JSONEncoder().encode(icon)
    #expect(try JSONDecoder().decode(ProjectIcon.self, from: data) == icon)
  }

  @Test
  func unknownPrefixThrows() {
    let data = Data("\"emoji:🚀\"".utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ProjectIcon.self, from: data)
    }
  }

  @Test
  func emptySymbolNameThrows() {
    let data = Data("\"sf:\"".utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ProjectIcon.self, from: data)
    }
  }

  /// A custom icon stores a bare file name. A hand-edited catalog carrying a
  /// path must be rejected, or the renderer would resolve outside the icon
  /// directory.
  @Test(arguments: ["\"file:\"", "\"file:../../etc/passwd\"", "\"file:sub/dir.svg\"", "\"file:..\""])
  func pathShapedCustomNamesThrow(raw: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ProjectIcon.self, from: Data(raw.utf8))
    }
  }

  // MARK: - Tint rule

  @Test
  func symbolsAlwaysFollowProjectColor() {
    #expect(ProjectIcon.symbol("terminal").followsProjectColor)
  }

  @Test(arguments: ["icon.svg", "icon.pdf", "ICON.SVG", "icon.PDF"])
  func vectorCustomIconsFollowProjectColor(fileName: String) {
    #expect(ProjectIcon.custom(fileName: fileName).followsProjectColor)
  }

  @Test(arguments: ["icon.png", "icon.jpg", "icon.heic", "icon.icns", "icon"])
  func rasterCustomIconsKeepTheirOwnColors(fileName: String) {
    #expect(!ProjectIcon.custom(fileName: fileName).followsProjectColor)
  }

  @Test
  func customFileNameIsExposedOnlyForCustomIcons() {
    #expect(ProjectIcon.custom(fileName: "a.svg").customFileName == "a.svg")
    #expect(ProjectIcon.symbol("folder").customFileName == nil)
  }

  /// Every tintable extension must also be importable, or the tint rule would
  /// describe a format the picker can never produce.
  @Test
  func tintableExtensionsAreASubsetOfSupportedOnes() {
    #expect(ProjectIcon.tintableExtensions.isSubset(of: ProjectIcon.supportedExtensions))
  }
}

/// Exercises the on-disk half: import validation, name shape, and the
/// copy-don't-reference guarantee.
struct ProjectIconStoreTests {
  private func makeTempConfigDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("project-icon-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeSource(_ name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("<svg/>".utf8).write(to: url)
    return url
  }

  @Test
  func importCopiesUnderAFreshUUIDNameAndKeepsTheExtension() throws {
    let config = try makeTempConfigDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let source = try writeSource("logo.svg", in: config)

    let fileName = try ProjectIconStore.importIcon(from: source, configDirectory: config)

    #expect(ProjectIcon.normalizedExtension(of: fileName) == "svg")
    #expect(UUID(uuidString: (fileName as NSString).deletingPathExtension) != nil)
    let stored = ProjectIconStore.fileURL(for: fileName, configDirectory: config)
    #expect(FileManager.default.fileExists(atPath: stored.path))
  }

  /// The copy is the point: the Project must keep its icon after the user
  /// moves or deletes the artwork they picked.
  @Test
  func importedIconSurvivesDeletionOfTheSource() throws {
    let config = try makeTempConfigDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let source = try writeSource("logo.svg", in: config)

    let fileName = try ProjectIconStore.importIcon(from: source, configDirectory: config)
    try FileManager.default.removeItem(at: source)

    let stored = ProjectIconStore.fileURL(for: fileName, configDirectory: config)
    #expect(FileManager.default.fileExists(atPath: stored.path))
  }

  @Test
  func importRejectsUnsupportedFormats() throws {
    let config = try makeTempConfigDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let source = try writeSource("notes.txt", in: config)

    #expect(throws: ProjectIconStore.ImportError.unsupportedFormat("txt")) {
      try ProjectIconStore.importIcon(from: source, configDirectory: config)
    }
  }

  @Test
  func repeatedImportsOfTheSameSourceGetDistinctNames() throws {
    let config = try makeTempConfigDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let source = try writeSource("logo.svg", in: config)

    let first = try ProjectIconStore.importIcon(from: source, configDirectory: config)
    let second = try ProjectIconStore.importIcon(from: source, configDirectory: config)

    // Distinct names are what make caching decoded images by name sound.
    #expect(first != second)
  }

  @Test
  func removeIconDeletesTheStoredFile() throws {
    let config = try makeTempConfigDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    let source = try writeSource("logo.svg", in: config)
    let fileName = try ProjectIconStore.importIcon(from: source, configDirectory: config)

    ProjectIconStore.removeIcon(named: fileName, configDirectory: config)

    let stored = ProjectIconStore.fileURL(for: fileName, configDirectory: config)
    #expect(!FileManager.default.fileExists(atPath: stored.path))
  }

  @Test
  func removeIconIsSilentForAMissingFile() throws {
    let config = try makeTempConfigDirectory()
    defer { try? FileManager.default.removeItem(at: config) }
    // No throw, no crash — orphan cleanup must never fail a catalog write.
    ProjectIconStore.removeIcon(named: "does-not-exist.svg", configDirectory: config)
  }
}
