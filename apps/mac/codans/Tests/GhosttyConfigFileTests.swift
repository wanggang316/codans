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

  private func draft(light: String? = nil, dark: String? = nil) -> GhosttyTerminalSettingsDraft {
    GhosttyTerminalSettingsDraft(lightTheme: light, darkTheme: dark)
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
    let input = "font-family = Menlo\nfont-size = 13\n"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "Alpha", dark: "Beta")
    )
    // Managed block lands at end-of-file because no managed key was present.
    // Trailing newline of the input is preserved; non-managed lines stay
    // in their original positions.
    #expect(out == "font-family = Menlo\nfont-size = 13\ntheme = light:Alpha,dark:Beta\n")
  }

  // MARK: - Replace in place

  @Test
  func existingThemeIsReplacedAtSamePosition() {
    let input = """
      font-family = Menlo
      theme = light:Old,dark:Old
      font-size = 13
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "New", dark: "Newer")
    )
    // The old managed line is at index 1; we drop it and re-insert at the
    // same index so non-managed siblings keep their relative position.
    #expect(
      out == """
        font-family = Menlo
        theme = light:New,dark:Newer
        font-size = 13
        """
    )
  }

  // MARK: - Multiple managed lines

  @Test
  func multipleInterleavedManagedLinesCollapseToSingleCanonicalBlock() {
    let input = """
      theme = light:A,dark:A
      font-family = Menlo
      theme = light:B,dark:B
      font-size = 13
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
        font-family = Menlo
        font-size = 13
        """
    )
  }

  // MARK: - Preserve comments & blanks

  @Test
  func commentsAndBlankLinesArePreservedAroundReplacement() {
    let input = """
      # top comment
      font-family = Menlo

      # before theme
      theme = light:Old,dark:Old
      # after theme

      font-size = 13
      """
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "New", dark: "New2")
    )
    #expect(
      out == """
        # top comment
        font-family = Menlo

        # before theme
        theme = light:New,dark:New2
        # after theme

        font-size = 13
        """
    )
  }

  // MARK: - Trailing newline

  @Test
  func trailingNewlineIsPreserved() {
    let input = "font-family = Menlo\n"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "A", dark: "B")
    )
    #expect(out.hasSuffix("\n"))
  }

  @Test
  func absentTrailingNewlineStaysAbsentForExistingFile() {
    let input = "font-family = Menlo"
    let out = GhosttyConfigFile.updatedContents(
      from: input,
      draft: draft(light: "A", dark: "B")
    )
    #expect(out == "font-family = Menlo\ntheme = light:A,dark:B")
  }

  // MARK: - Draft both nil removes block

  @Test
  func draftBothNilRemovesManagedBlockLeavingRest() {
    let input = """
      font-family = Menlo
      theme = light:X,dark:Y
      font-size = 13
      """
    let out = GhosttyConfigFile.updatedContents(from: input, draft: draft())
    #expect(
      out == """
        font-family = Menlo
        font-size = 13
        """
    )
  }

  @Test
  func draftBothNilOnFileWithNoManagedKeysIsIdentity() {
    let input = """
      font-family = Menlo
      font-size = 13
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
      font-family = Menlo
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
        font-family = Menlo
        theme = light:A,dark:B
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
