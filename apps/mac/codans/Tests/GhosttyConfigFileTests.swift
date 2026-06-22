import Foundation
import Testing

@testable import Codans

/// Unit tests for `GhosttyConfigFile.updatedContents` — the pure transform
/// that rewrites the managed block. The live reader/writer paths (`load` /
/// `apply`) touch the real filesystem and libghostty; they're exercised in
/// M5's manual + integration pass, not here.
@MainActor
struct GhosttyConfigFileTests {
  // MARK: - Helpers

  private func draft(
    light: String? = nil,
    dark: String? = nil,
    cursorStyle: GhosttyCursorStyle? = nil,
    fontFamily: String? = nil,
    fontSize: Double? = nil,
    backgroundOpacity: Double? = nil,
    backgroundBlur: GhosttyBackgroundBlur? = nil
  ) -> GhosttyTerminalSettingsDraft {
    GhosttyTerminalSettingsDraft(
      lightTheme: light,
      darkTheme: dark,
      cursorStyle: cursorStyle,
      fontFamily: fontFamily,
      fontSize: fontSize,
      backgroundOpacity: backgroundOpacity,
      backgroundBlur: backgroundBlur
    )
  }

  // MARK: - Empty file

  @Test
  func emptyFileGetsManagedBlockInserted() {
    let out = GhosttyConfigFile.updatedContents(
      from: "",
      draft: draft(light: "Alpha", dark: "Beta")
    )
    #expect(out == "theme = light:Alpha,dark:Beta\n")
  }

  @Test
  func emptyFileWithBothNilProducesEmptyOutput() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft())
    #expect(out == "")
  }

  // MARK: - Non-managed content

  @Test
  func nonManagedContentGetsBlockAppended() {
    let input = "window-padding-x = 4\nscrollback-limit = 10000\n"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "Alpha", dark: "Beta")
    )
    // Managed block lands at end-of-file because no managed key was present.
    // Trailing newline of the input is preserved; non-managed lines stay
    // in their original positions.
    #expect(out == "window-padding-x = 4\nscrollback-limit = 10000\ntheme = light:Alpha,dark:Beta\n")
  }

  // MARK: - Replace in place

  @Test
  func existingThemeIsReplacedAtSamePosition() {
    let input = """
      window-padding-x = 4
      theme = light:Old,dark:Old
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "New", dark: "Newer")
    )
    // The old managed line is at index 1; we drop it and re-insert at the
    // same index so non-managed siblings keep their relative position.
    #expect(
      out == """
        window-padding-x = 4
        theme = light:New,dark:Newer
        scrollback-limit = 10000
        """
    )
  }

  // MARK: - Multiple managed lines

  @Test
  func multipleInterleavedManagedLinesCollapseToSingleCanonicalBlock() {
    let input = """
      theme = light:A,dark:A
      window-padding-x = 4
      theme = light:B,dark:B
      scrollback-limit = 10000
      theme = light:C,dark:C
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "Final", dark: "Final")
    )
    // Canonical block lands at the earliest managed index (0); the other
    // two `theme = …` lines are removed.
    #expect(
      out == """
        theme = light:Final,dark:Final
        window-padding-x = 4
        scrollback-limit = 10000
        """
    )
  }

  // MARK: - Preserve comments & blanks

  @Test
  func commentsAndBlankLinesArePreservedAroundReplacement() {
    let input = """
      # top comment
      window-padding-x = 4

      # before theme
      theme = light:Old,dark:Old
      # after theme

      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "New", dark: "New2")
    )
    #expect(
      out == """
        # top comment
        window-padding-x = 4

        # before theme
        theme = light:New,dark:New2
        # after theme

        scrollback-limit = 10000
        """
    )
  }

  // MARK: - Trailing newline

  @Test
  func trailingNewlineIsPreserved() {
    let input = "window-padding-x = 4\n"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "A", dark: "B")
    )
    #expect(out.hasSuffix("\n"))
  }

  @Test
  func absentTrailingNewlineStaysAbsentForExistingFile() {
    let input = "window-padding-x = 4"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "A", dark: "B")
    )
    #expect(out == "window-padding-x = 4\ntheme = light:A,dark:B")
  }

  // MARK: - Draft both nil removes block

  @Test
  func draftBothNilRemovesManagedBlockLeavingRest() {
    let input = """
      window-padding-x = 4
      theme = light:X,dark:Y
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(from: input, draft: draft())
    #expect(
      out == """
        window-padding-x = 4
        scrollback-limit = 10000
        """
    )
  }

  @Test
  func draftBothNilOnFileWithNoManagedKeysIsIdentity() {
    let input = """
      window-padding-x = 4
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(from: input, draft: draft())
    #expect(out == input)
  }

  // MARK: - Mirror semantics

  @Test
  func lightOnlyMirrorsToDark() {
    let out = GhosttyConfigFile.updatedContents(
      from: "",
      draft: draft(light: "Solarized Light")
    )
    #expect(out == "theme = light:Solarized Light,dark:Solarized Light\n")
  }

  @Test
  func darkOnlyMirrorsToLight() {
    let out = GhosttyConfigFile.updatedContents(
      from: "",
      draft: draft(dark: "Solarized Dark")
    )
    #expect(out == "theme = light:Solarized Dark,dark:Solarized Dark\n")
  }

  // MARK: - Directive key detection edge cases

  @Test
  func caseInsensitiveKeyMatch() {
    // `Theme` (capitalized) is the same directive — it should be treated
    // as managed and replaced, not kept alongside the canonical block.
    let input = "Theme = light:Old,dark:Old\n"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "New", dark: "New")
    )
    #expect(out == "theme = light:New,dark:New\n")
  }

  @Test
  func commentedThemeLineIsNotReplaced() {
    let input = """
      # theme = light:X,dark:Y
      window-padding-x = 4
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "A", dark: "B")
    )
    // The `# theme = …` line is a comment — we must not drop it. The new
    // managed block is appended at end of file since no real managed key
    // was present.
    #expect(
      out == """
        # theme = light:X,dark:Y
        window-padding-x = 4
        theme = light:A,dark:B
        """
    )
  }

  // MARK: - Cursor style

  @Test
  func cursorStyleOnlyEmitsSingleDirective() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(cursorStyle: .bar))
    #expect(out == "cursor-style = bar\n")
  }

  @Test
  func themeAndCursorStyleEmitInStableOrder() {
    let out = GhosttyConfigFile.updatedContents(
      from: "",
      draft: draft(light: "Alpha", dark: "Beta", cursorStyle: .underline)
    )
    #expect(out == "theme = light:Alpha,dark:Beta\ncursor-style = underline\n")
  }

  @Test
  func hollowBlockUsesUnderscoreToken() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(cursorStyle: .blockHollow))
    #expect(out == "cursor-style = block_hollow\n")
  }

  @Test
  func existingCursorStyleIsReplacedInPlace() {
    let input = """
      window-padding-x = 4
      cursor-style = block
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(from: input, draft: draft(cursorStyle: .bar))
    #expect(
      out == """
        window-padding-x = 4
        cursor-style = bar
        scrollback-limit = 10000
        """
    )
  }

  @Test
  func nilCursorStyleStripsManagedDirectiveLeavingTheme() {
    let input = """
      cursor-style = bar
      theme = light:X,dark:Y
      scrollback-limit = 10000
      """
    // Draft keeps the theme but drops cursor-style: the directive is removed.
    let out = GhosttyConfigFile.updatedContents(from: input, draft: draft(light: "X", dark: "Y"))
    #expect(
      out == """
        theme = light:X,dark:Y
        scrollback-limit = 10000
        """
    )
  }

  // MARK: - Font

  @Test
  func fontFamilyEmitsDirectiveVerbatim() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(fontFamily: "JetBrains Mono"))
    #expect(out == "font-family = JetBrains Mono\n")
  }

  @Test
  func emptyFontFamilyEmitsNoDirective() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(fontFamily: ""))
    #expect(out == "")
  }

  @Test
  func wholeFontSizeEmitsWithoutDecimal() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(fontSize: 14))
    #expect(out == "font-size = 14\n")
  }

  @Test
  func fractionalFontSizeKeepsDecimal() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(fontSize: 13.5))
    #expect(out == "font-size = 13.5\n")
  }

  @Test
  func allManagedDirectivesEmitInStableOrder() {
    let out = GhosttyConfigFile.updatedContents(
      from: "",
      draft: draft(
        light: "L", dark: "D", cursorStyle: .bar, fontFamily: "Fira Code", fontSize: 12
      )
    )
    #expect(
      out == """
        theme = light:L,dark:D
        font-family = Fira Code
        font-size = 12
        cursor-style = bar

        """
    )
  }

  @Test
  func existingFontDirectivesReplacedInPlace() {
    let input = """
      window-padding-x = 4
      font-family = Menlo
      font-size = 13
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(fontFamily: "Fira Code", fontSize: 15)
    )
    #expect(
      out == """
        window-padding-x = 4
        font-family = Fira Code
        font-size = 15
        scrollback-limit = 10000
        """
    )
  }

  // MARK: - Background opacity & blur

  @Test
  func backgroundOpacityEmitsFractionalValue() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(backgroundOpacity: 0.9))
    #expect(out == "background-opacity = 0.9\n")
  }

  @Test
  func wholeBackgroundOpacityEmitsWithoutDecimal() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(backgroundOpacity: 1))
    #expect(out == "background-opacity = 1\n")
  }

  @Test
  func regularGlassBlurEmitsToken() {
    let out = GhosttyConfigFile.updatedContents(
      from: "", draft: draft(backgroundBlur: .regularGlass))
    #expect(out == "background-blur = macos-glass-regular\n")
  }

  @Test
  func clearGlassBlurEmitsToken() {
    let out = GhosttyConfigFile.updatedContents(from: "", draft: draft(backgroundBlur: .clearGlass))
    #expect(out == "background-blur = macos-glass-clear\n")
  }

  @Test
  func backgroundDirectivesEmitAfterCursorInStableOrder() {
    let out = GhosttyConfigFile.updatedContents(
      from: "",
      draft: draft(
        light: "L", dark: "D", cursorStyle: .bar, fontFamily: "Fira Code", fontSize: 12,
        backgroundOpacity: 0.85, backgroundBlur: .regularGlass
      )
    )
    #expect(
      out == """
        theme = light:L,dark:D
        font-family = Fira Code
        font-size = 12
        cursor-style = bar
        background-opacity = 0.85
        background-blur = macos-glass-regular

        """
    )
  }

  @Test
  func existingBackgroundDirectivesReplacedInPlace() {
    let input = """
      window-padding-x = 4
      background-opacity = 0.5
      background-blur = macos-glass-clear
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(backgroundOpacity: 0.9, backgroundBlur: .regularGlass)
    )
    #expect(
      out == """
        window-padding-x = 4
        background-opacity = 0.9
        background-blur = macos-glass-regular
        scrollback-limit = 10000
        """
    )
  }

  @Test
  func nilBackgroundStripsDirectivesLeavingTheme() {
    let input = """
      background-opacity = 0.9
      theme = light:X,dark:Y
      background-blur = macos-glass-regular
      scrollback-limit = 10000
      """
    let out = GhosttyConfigFile.updatedContents(from: input, draft: draft(light: "X", dark: "Y"))
    #expect(
      out == """
        theme = light:X,dark:Y
        scrollback-limit = 10000
        """
    )
  }
}

// MARK: - Config path resolution

/// Exercises `resolvedConfigURL` against a synthesised HOME so the tests
/// never touch the developer's real config tree. The contract is
/// intentionally simple: always `$XDG_CONFIG_HOME/ghostty/config`, defaulting
/// to `~/.config/ghostty/config`. We deliberately don't target the
/// `~/Library/Application Support/com.mitchellh.ghostty` tree that upstream
/// Ghostty probes — writes there would land in a file the user doesn't
/// expect us to touch.
@MainActor
struct GhosttyConfigPathResolutionTests {
  private final class TemporaryHome {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ghostty-config-home-\(UUID().uuidString)",
        isDirectory: true
      )
      try? FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true
      )
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  private func makeConfigFile(home: TemporaryHome, environment: [String: String] = [:])
    -> GhosttyConfigFile
  {
    GhosttyConfigFile(
      homeDirectoryURL: home.url,
      environment: environment,
      catalogProvider: { .empty }
    )
  }

  @Test
  func resolvesToXdgConfigInHomeByDefault() {
    let home = TemporaryHome()
    let resolved = makeConfigFile(home: home).resolvedConfigURL()
    #expect(
      resolved.path
        == home.url.appendingPathComponent(".config/ghostty/config").path
    )
  }

  @Test
  func xdgConfigHomeEnvVarOverridesDefault() {
    let home = TemporaryHome()
    let xdgRoot = TemporaryHome()
    let resolved = makeConfigFile(
      home: home,
      environment: ["XDG_CONFIG_HOME": xdgRoot.url.path]
    ).resolvedConfigURL()
    #expect(
      resolved.path
        == xdgRoot.url.appendingPathComponent("ghostty/config").path
    )
  }
}
