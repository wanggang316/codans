import Foundation
import os.log

/// Sorted lists of theme names bundled with / installed for Ghostty, split by
/// perceived luminance of their `background` directive. Consumers (the
/// Appearance settings pane) render two pickers directly from this pair.
///
/// `Equatable` so TCA state can diff; `Sendable` so the struct can cross
/// actor boundaries freely.
nonisolated struct GhosttyThemeCatalog: Equatable, Sendable {
  /// Theme names whose background luminance classifies as light (Y > 0.5),
  /// sorted with `localizedStandardCompare` so `"abc2"` < `"abc10"`.
  let light: [String]

  /// Theme names that did not classify as light. Includes files without a
  /// parseable `background` directive — Ghostty itself falls back to dark.
  let dark: [String]

  /// Parsed color directives keyed by theme name. Populated alongside the
  /// classification (same file read) so the Settings picker can render
  /// swatches without re-touching disk. A missing entry means the file was
  /// unreadable; an empty `GhosttyThemePreview` means it was readable but had
  /// no parseable color directives — both render as neutral chrome.
  let previews: [String: GhosttyThemePreview]

  static let empty = GhosttyThemeCatalog(light: [], dark: [], previews: [:])
}

/// Read-only, best-effort enumerator of Ghostty theme files. Never throws;
/// missing directories yield empty arrays. Classification is cheap enough
/// (one line scan per file) to run on demand when the Appearance pane opens.
@MainActor
enum GhosttyThemeCatalogReader {
  private static let logger = Logger(
    subsystem: "app.touch-code.mac",
    category: "appearance"
  )

  /// Enumerate user + Ghostty-bundled theme directories and classify each file.
  ///
  /// Priorities (a theme name appearing in more than one directory is
  /// deduplicated; first-seen wins for classification, so a user-authored
  /// theme shadows a bundled one with the same filename):
  /// 1. `$XDG_CONFIG_HOME/ghostty/themes`
  /// 2. `$HOME/.config/ghostty/themes`
  /// 3. `$GHOSTTY_RESOURCES_DIR/themes` — Ghostty's own bundled themes.
  ///    `GhosttyBootstrap.initialize` sets this env var at process startup,
  ///    so by the time Settings → Terminal opens the directory is discoverable
  ///    here without touching the runtime struct directly.
  /// 4. `$TOUCH_CODE_GHOSTTY_RESOURCES/ghostty/themes` — dev override that
  ///    `GhosttyBootstrap` honors first.
  /// 5. `<repo>/.build/ghostty/share/ghostty/themes` — dev fallback used by
  ///    `GhosttyBootstrap` when Xcode runs the target without a bundled
  ///    resources copy.
  /// 6. `Bundle.main.resourceURL/ghostty/themes` — only populated if we ever
  ///    copy themes into the .app's Resources.
  ///
  /// Parameters default to production sources but are injectable for tests.
  static func load(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> GhosttyThemeCatalog {
    let searchRoots = candidateThemeDirectories(
      homeDirectoryURL: homeDirectoryURL,
      environment: environment
    )

    var lightSet: Set<String> = []
    var darkSet: Set<String> = []
    var previews: [String: GhosttyThemePreview] = [:]
    var seen: Set<String> = []

    for root in searchRoots {
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }

      for entry in entries {
        let name = entry.lastPathComponent
        if seen.contains(name) { continue }
        // Skip sub-directories; Ghostty themes are flat files.
        let isRegular = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        guard isRegular else { continue }
        seen.insert(name)

        let preview = parseThemeFile(at: entry)
        previews[name] = preview ?? .empty
        switch classify(preview: preview) {
        case .light:
          lightSet.insert(name)
        case .dark:
          darkSet.insert(name)
        case .unclassified:
          // Match Ghostty's default fallback. Logged so operators can audit
          // unexpected theme files that don't carry a background directive.
          logger.info("theme-catalog unclassified theme=\(name, privacy: .public)")
          darkSet.insert(name)
        }
      }
    }

    let sort: ([String]) -> [String] = { names in
      names.sorted { lhs, rhs in
        lhs.localizedStandardCompare(rhs) == .orderedAscending
      }
    }
    return GhosttyThemeCatalog(
      light: sort(Array(lightSet)),
      dark: sort(Array(darkSet)),
      previews: previews
    )
  }

  // MARK: - Search path resolution

  /// Returns every on-disk directory we should probe, in priority order.
  /// Missing directories are still included — the caller `contentsOfDirectory`
  /// short-circuits on ENOENT without error.
  static func candidateThemeDirectories(
    homeDirectoryURL: URL,
    environment: [String: String]
  ) -> [URL] {
    var roots: [URL] = []

    // User-writable paths first so custom themes shadow bundled ones.
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      roots.append(
        URL(fileURLWithPath: xdg, isDirectory: true)
          .appendingPathComponent("ghostty", isDirectory: true)
          .appendingPathComponent("themes", isDirectory: true)
      )
    }
    roots.append(
      homeDirectoryURL
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("ghostty", isDirectory: true)
        .appendingPathComponent("themes", isDirectory: true)
    )

    // GhosttyBootstrap exports GHOSTTY_RESOURCES_DIR at startup pointing at
    // Ghostty's own resources tree — that's where the ~200 bundled themes live.
    if let resourcesDir = environment["GHOSTTY_RESOURCES_DIR"], !resourcesDir.isEmpty {
      roots.append(
        URL(fileURLWithPath: resourcesDir, isDirectory: true)
          .appendingPathComponent("themes", isDirectory: true)
      )
    }
    // Dev override and the SRCROOT-relative fallback both mirror the layout
    // `GhosttyBootstrap.resolveResourceDirs` probes so tests and unbundled
    // `xcodebuild run` flows still see themes even when GHOSTTY_RESOURCES_DIR
    // was not set for some reason (e.g. Settings opened before bringUp ran).
    if let override = environment["TOUCH_CODE_GHOSTTY_RESOURCES"], !override.isEmpty {
      roots.append(
        URL(fileURLWithPath: override, isDirectory: true)
          .appendingPathComponent("ghostty", isDirectory: true)
          .appendingPathComponent("themes", isDirectory: true)
      )
    }
    // Test escape hatch: `#filePath`-based dev fallback below always resolves to
    // a populated `.build/ghostty/share/ghostty/themes` inside a developer
    // worktree, which pollutes "empty catalog" assertions. Tests set this env
    // key to opt out of the implicit fallback while still being able to drive
    // explicit roots via XDG_CONFIG_HOME / HOME / GHOSTTY_RESOURCES_DIR.
    let suppressImplicit = environment["TOUCH_CODE_DISABLE_THEME_DEV_FALLBACK"] == "1"
    if !suppressImplicit, let devFallback = srcrootGhosttyThemesDirectory() {
      roots.append(devFallback)
    }

    // Last resort: .app-bundled themes if we ever ship them as Tuist resources.
    if !suppressImplicit, let resourceURL = Bundle.main.resourceURL {
      roots.append(
        resourceURL
          .appendingPathComponent("ghostty", isDirectory: true)
          .appendingPathComponent("themes", isDirectory: true)
      )
    }
    return roots
  }

  /// Locate `<repo>/apps/mac/.build/ghostty/share/ghostty/themes` via
  /// `#filePath`. Returns nil when the file is running from an installed
  /// location (e.g. a signed .app) where the relative ascent wouldn't resolve.
  private static func srcrootGhosttyThemesDirectory() -> URL? {
    // #filePath → .../apps/mac/touch-code/Runtime/Ghostty/GhosttyThemeCatalog.swift
    // Ascend four levels to land at apps/mac, then descend into the build tree.
    let file = URL(fileURLWithPath: #filePath)
    let appsMac =
      file
      .deletingLastPathComponent()  // Ghostty
      .deletingLastPathComponent()  // Runtime
      .deletingLastPathComponent()  // touch-code
      .deletingLastPathComponent()  // mac
    let candidate =
      appsMac
      .appendingPathComponent(".build/ghostty/share/ghostty/themes", isDirectory: true)
    return candidate
  }

  // MARK: - Classification

  private enum Classification { case light, dark, unclassified }

  /// Map a parsed preview to a light/dark classification using the same
  /// luminance threshold as before. A missing or unparseable background →
  /// `.unclassified`, which the caller maps to dark.
  private static func classify(preview: GhosttyThemePreview?) -> Classification {
    guard let background = preview?.background else { return .unclassified }
    let y = 0.299 * background.r + 0.587 * background.g + 0.114 * background.b
    return y > 0.5 ? .light : .dark
  }

  // MARK: - Theme file parsing

  /// Read a theme file (best-effort UTF-8) and extract the color directives
  /// the preview UI cares about. Returns `nil` only on I/O failure — an empty
  /// file or a file with zero parseable directives still returns a struct
  /// (with all-`nil` fields) so the catalog can record that we tried.
  static func parseThemeFile(at fileURL: URL) -> GhosttyThemePreview? {
    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return nil
    }
    var background: GhosttyThemePreview.RGB?
    var foreground: GhosttyThemePreview.RGB?
    var cursor: GhosttyThemePreview.RGB?
    var palette: [Int: GhosttyThemePreview.RGB] = [:]

    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      // Strip `#` comments. A `#RRGGBB` value is distinguished from a
      // comment only by position — comments start the line; color literals
      // appear after `=`.
      if line.isEmpty || line.hasPrefix("#") { continue }
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

      switch key {
      case "background":
        background = parseColor(value)
      case "foreground":
        foreground = parseColor(value)
      case "cursor-color":
        cursor = parseColor(value)
      case "palette":
        // `palette = N=<color>`. Split once on '=' inside the value half.
        guard let inner = value.firstIndex(of: "=") else { continue }
        let indexPart = value[..<inner].trimmingCharacters(in: .whitespaces)
        let colorPart = value[value.index(after: inner)...].trimmingCharacters(in: .whitespaces)
        guard let idx = Int(indexPart), (0...15).contains(idx),
          let rgb = parseColor(String(colorPart))
        else { continue }
        palette[idx] = rgb
      default:
        continue
      }
    }
    return GhosttyThemePreview(
      background: background,
      foreground: foreground,
      cursor: cursor,
      palette: palette
    )
  }

  /// Parse the three color formats Ghostty accepts for color directives:
  /// - `#RRGGBB` (hex with leading hash)
  /// - `RRGGBB` (bare hex)
  /// - `r:g:b` (decimal tuple, 0–255 per channel)
  ///
  /// Returned channels are normalized to 0–1.
  fileprivate static func parseColor(_ raw: String) -> GhosttyThemePreview.RGB? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.contains(":") {
      let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 3,
        let r = UInt8(parts[0].trimmingCharacters(in: .whitespaces)),
        let g = UInt8(parts[1].trimmingCharacters(in: .whitespaces)),
        let b = UInt8(parts[2].trimmingCharacters(in: .whitespaces))
      else { return nil }
      return GhosttyThemePreview.RGB(
        r: Double(r) / 255.0,
        g: Double(g) / 255.0,
        b: Double(b) / 255.0
      )
    }
    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard hex.count == 6,
      let value = UInt32(hex, radix: 16)
    else { return nil }
    return GhosttyThemePreview.RGB(
      r: Double((value >> 16) & 0xFF) / 255.0,
      g: Double((value >> 8) & 0xFF) / 255.0,
      b: Double(value & 0xFF) / 255.0
    )
  }
}
