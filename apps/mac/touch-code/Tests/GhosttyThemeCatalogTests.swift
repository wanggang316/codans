import Foundation
import Testing

@testable import TouchCode

/// Unit tests for `GhosttyThemeCatalogReader.load`. Covers directory
/// discovery via `XDG_CONFIG_HOME` + `~/.config/ghostty/themes`, the
/// background-luminance classifier, and the stable localized sort.
@MainActor
struct GhosttyThemeCatalogTests {
  // MARK: - Helpers

  /// Scoped temporary directory with automatic cleanup in `deinit`.
  /// We model this as a class (reference type) so `deinit` can run when the
  /// test value goes out of scope without needing explicit teardown hooks.
  final class TemporaryDirectory {
    let url: URL

    init() {
      let base = FileManager.default.temporaryDirectory
      url = base.appendingPathComponent(
        "ghostty-theme-catalog-\(UUID().uuidString)",
        isDirectory: true
      )
      try? FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true
      )
    }

    deinit {
      try? FileManager.default.removeItem(at: url)
    }

    /// Create a theme file under a `ghostty/themes` subtree rooted at this
    /// directory. Mirrors the on-disk layout the reader expects when the
    /// parent dir is passed in via `XDG_CONFIG_HOME`.
    func writeThemeFile(named name: String, contents: String) throws -> URL {
      let themesDir =
        url
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("themes", isDirectory: true)
      try FileManager.default.createDirectory(
        at: themesDir, withIntermediateDirectories: true
      )
      let fileURL = themesDir.appendingPathComponent(name)
      try contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL
    }
  }

  /// A throwaway HOME that has no `.config/ghostty/themes` so tests that set
  /// `XDG_CONFIG_HOME` are never polluted by the developer's real themes.
  private func emptyHome() -> TemporaryDirectory { TemporaryDirectory() }

  private func load(
    xdg: TemporaryDirectory,
    home: TemporaryDirectory
  ) -> GhosttyThemeCatalog {
    GhosttyThemeCatalogReader.load(
      homeDirectoryURL: home.url,
      environment: [
        "XDG_CONFIG_HOME": xdg.url.path,
        "TOUCH_CODE_DISABLE_THEME_DEV_FALLBACK": "1",
      ]
    )
  }

  // MARK: - Tests

  @Test
  func emptyDirectoryYieldsEmptyArrays() {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    // No themes dir exists yet under either root.
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.light.isEmpty)
    #expect(catalog.dark.isEmpty)
  }

  @Test
  func singleLightThemeClassifiedAsLight() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(named: "Paperlike", contents: "background = #FFFFFF\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.light == ["Paperlike"])
    #expect(catalog.dark.isEmpty)
  }

  @Test
  func singleDarkThemeClassifiedAsDark() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(named: "Midnight", contents: "background = #000000\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.dark == ["Midnight"])
    #expect(catalog.light.isEmpty)
  }

  @Test
  func mixedCaseHexParses() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    // #AbCdEf → R=0xAb=171, G=0xCd=205, B=0xEf=239. Y ≈ 0.80 → light.
    _ = try xdg.writeThemeFile(named: "MixedCase", contents: "background = #AbCdEf\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.light == ["MixedCase"])
    #expect(catalog.dark.isEmpty)
  }

  @Test
  func bareHexWithoutHashParses() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(named: "NoHash", contents: "background = FFFFFF\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.light == ["NoHash"])
  }

  @Test
  func decimalTripleColorParses() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(named: "Triple", contents: "background = 255:255:255\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.light == ["Triple"])
  }

  @Test
  func noBackgroundDirectiveFallsBackToDark() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(
      named: "PaletteOnly",
      contents: "palette = 0=#000000\npalette = 1=#ffffff\n"
    )
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.dark == ["PaletteOnly"])
    #expect(catalog.light.isEmpty)
  }

  @Test
  func unparseableColorFallsBackToDark() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(named: "Broken", contents: "background = not-a-color\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.dark == ["Broken"])
    #expect(catalog.light.isEmpty)
  }

  @Test
  func alphabeticalSortUsesLocalizedStandardCompare() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    // localizedStandardCompare orders "theme2" before "theme10" — unlike
    // default ASCII sort which would put "theme10" first.
    _ = try xdg.writeThemeFile(named: "theme10", contents: "background = #000000\n")
    _ = try xdg.writeThemeFile(named: "theme2", contents: "background = #000000\n")
    _ = try xdg.writeThemeFile(named: "theme1", contents: "background = #000000\n")
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.dark == ["theme1", "theme2", "theme10"])
  }

  @Test
  func commentLinesAreIgnored() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(
      named: "Commented",
      contents: """
        # comment
        # background = #FFFFFF   (not a real directive)
        background = #000000
        """
    )
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.dark == ["Commented"])
    #expect(catalog.light.isEmpty)
  }

  @Test
  func homeFallbackUsedWhenXDGIsMissing() throws {
    // Leave XDG_CONFIG_HOME unset; write into HOME/.config/ghostty/themes.
    let home = TemporaryDirectory()
    let themesDir = home.url
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("ghostty", isDirectory: true)
      .appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(
      at: themesDir, withIntermediateDirectories: true
    )
    try "background = #FFFFFF\n".write(
      to: themesDir.appendingPathComponent("HomeLight"),
      atomically: true,
      encoding: .utf8
    )
    let catalog = GhosttyThemeCatalogReader.load(
      homeDirectoryURL: home.url,
      environment: ["TOUCH_CODE_DISABLE_THEME_DEV_FALLBACK": "1"]
    )
    #expect(catalog.light.contains("HomeLight"))
  }

  @Test
  func themeInBothXDGAndHomeDeduplicates() throws {
    let xdg = TemporaryDirectory()
    let home = TemporaryDirectory()
    _ = try xdg.writeThemeFile(named: "Shared", contents: "background = #000000\n")
    // Different background under HOME — first-seen wins (XDG has priority).
    let homeThemes = home.url
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("ghostty", isDirectory: true)
      .appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(
      at: homeThemes, withIntermediateDirectories: true
    )
    try "background = #FFFFFF\n".write(
      to: homeThemes.appendingPathComponent("Shared"),
      atomically: true,
      encoding: .utf8
    )
    let catalog = load(xdg: xdg, home: home)
    #expect(catalog.dark == ["Shared"])
    #expect(catalog.light.isEmpty)
  }

  @Test
  func ghosttyResourcesDirEnvVarContributesBundledThemes() throws {
    let home = TemporaryDirectory()
    // Simulate Ghostty's bundled themes tree: <resources>/themes/<file>.
    let resources = TemporaryDirectory()
    let themesDir = resources.url.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(
      at: themesDir, withIntermediateDirectories: true
    )
    try "background = #101010\n".write(
      to: themesDir.appendingPathComponent("Bundled Dark"),
      atomically: true,
      encoding: .utf8
    )
    try "background = #F0F0F0\n".write(
      to: themesDir.appendingPathComponent("Bundled Light"),
      atomically: true,
      encoding: .utf8
    )
    let catalog = GhosttyThemeCatalogReader.load(
      homeDirectoryURL: home.url,
      environment: [
        "GHOSTTY_RESOURCES_DIR": resources.url.path,
        "TOUCH_CODE_DISABLE_THEME_DEV_FALLBACK": "1",
      ]
    )
    #expect(catalog.dark.contains("Bundled Dark"))
    #expect(catalog.light.contains("Bundled Light"))
  }

  @Test
  func previewCapturesBackgroundForegroundAndPalette() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(
      named: "Sample",
      contents: """
        background = #102030
        foreground = #fafbfc
        cursor-color = #ff0000
        palette = 0=#000000
        palette = 1=#db2d20
        palette = 4=#01a0e4
        palette = 15=#ffffff
        """
    )
    let catalog = load(xdg: xdg, home: home)
    let preview = try #require(catalog.previews["Sample"])
    #expect(preview.background?.r == 0x10 / 255.0)
    #expect(preview.foreground?.r == 0xFA / 255.0)
    #expect(preview.cursor?.r == 1.0)
    #expect(preview.palette[1]?.r == 0xDB / 255.0)
    #expect(preview.palette[4]?.b == 0xE4 / 255.0)
    #expect(preview.palette[15]?.r == 1.0)
    // Unset palette slots stay absent.
    #expect(preview.palette[7] == nil)
  }

  @Test
  func previewIsEmptyButPresentWhenThemeHasNoColorDirectives() throws {
    let xdg = TemporaryDirectory()
    let home = emptyHome()
    _ = try xdg.writeThemeFile(named: "Sparse", contents: "# only a comment\n")
    let catalog = load(xdg: xdg, home: home)
    let preview = try #require(catalog.previews["Sparse"])
    #expect(preview.background == nil)
    #expect(preview.foreground == nil)
    #expect(preview.palette.isEmpty)
  }

  @Test
  func userThemeShadowsGhosttyBundledThemeOfSameName() throws {
    let xdg = TemporaryDirectory()
    let home = TemporaryDirectory()
    let resources = TemporaryDirectory()
    // Bundled version is dark.
    let bundledThemes = resources.url.appendingPathComponent("themes", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundledThemes, withIntermediateDirectories: true
    )
    try "background = #000000\n".write(
      to: bundledThemes.appendingPathComponent("Conflicting"),
      atomically: true,
      encoding: .utf8
    )
    // User version at XDG is light — should win per priority order.
    _ = try xdg.writeThemeFile(named: "Conflicting", contents: "background = #FFFFFF\n")

    let catalog = GhosttyThemeCatalogReader.load(
      homeDirectoryURL: home.url,
      environment: [
        "XDG_CONFIG_HOME": xdg.url.path,
        "GHOSTTY_RESOURCES_DIR": resources.url.path,
        "TOUCH_CODE_DISABLE_THEME_DEV_FALLBACK": "1",
      ]
    )
    #expect(catalog.light == ["Conflicting"])
    #expect(!catalog.dark.contains("Conflicting"))
  }
}
