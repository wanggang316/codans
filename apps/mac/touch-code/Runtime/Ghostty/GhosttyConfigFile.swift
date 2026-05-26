import Foundation
import GhosttyKit
import os.log

// `Notification.Name.ghosttyRuntimeReloadRequested` is declared alongside its sole
// observer in `GhosttyRuntime.swift`; `apply(_:)` posts through that canonical symbol.

// MARK: - Errors

/// Surfaced by `GhosttyConfigFile.load` / `apply`. `LocalizedError` so the
/// Settings pane can render the description directly; every case carries
/// enough context to diagnose without the underlying error.
nonisolated enum GhosttyConfigFileError: LocalizedError {
  /// The OS could not resolve a HOME / XDG path we need. Message is
  /// operator-oriented (e.g. "HOME is empty").
  case configDirectoryUnavailable(String)
  /// After writing a candidate file, libghostty reported diagnostics.
  /// Message is the first diagnostic text.
  case validationFailed(String)
  /// Foundation-level I/O error (read, write, atomic swap). Preserves the
  /// underlying error for localized rendering.
  case ioError(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .configDirectoryUnavailable(let reason):
      return "Ghostty config directory is unavailable: \(reason)"
    case .validationFailed(let message):
      return "Ghostty rejected the new config: \(message)"
    case .ioError(let underlying):
      return "I/O error writing Ghostty config: \(underlying.localizedDescription)"
    }
  }
}

// MARK: - Values

/// Snapshot of the user's current Ghostty terminal-appearance state, as
/// observable by the Settings pane. Carries both the user-selected themes
/// (nil ⇒ no managed directive in file) and the enumerated catalog so the
/// pane can populate pickers from a single payload.
nonisolated struct GhosttyTerminalSettings: Equatable, Sendable {
  /// Canonical config-file path we read from / would write to. Stable for
  /// a given `GhosttyConfigFile` instance.
  let configPath: String
  /// Light theme selected via `theme = light:<X>,dark:<Y>`. `nil` when no
  /// managed directive exists or the directive was malformed.
  let lightTheme: String?
  let darkTheme: String?
  /// Enumerated catalog of themes on disk. Not necessarily containing
  /// `lightTheme` / `darkTheme` — see callers that prepend missing entries.
  let availableLightThemes: [String]
  let availableDarkThemes: [String]
  /// Parsed color directives keyed by theme name. Used by the Settings →
  /// Terminal picker to render swatches + a hover preview without re-touching
  /// disk. Missing entries (or empty previews) render as neutral chrome.
  let themePreviews: [String: GhosttyThemePreview]
  /// Non-nil when the user's config contains a non-split `theme = X`
  /// directive. Surfaced so the pane can warn before overwrite.
  let warningMessage: String?
}

/// User-intent payload for `apply`. Nil fields mean "don't emit a managed
/// theme directive" — on commit the managed block is removed entirely when
/// both are nil. Mirror behaviour (both nil → no directive; one nil → both
/// set to the non-nil value) is applied inside `apply` so the pane can
/// defer the decision.
nonisolated struct GhosttyTerminalSettingsDraft: Equatable, Sendable {
  let lightTheme: String?
  let darkTheme: String?
}

// MARK: - Reader / Writer

/// Pure reader/writer for `~/.config/ghostty/config`. No libghostty runtime
/// dependency for `load` / pure transforms — just Foundation + the catalog
/// provider. `apply` round-trips through libghostty to validate the new
/// file before the atomic swap.
///
/// `@MainActor` because the catalog provider closes over main-actor state
/// (`Bundle.main`, etc.) and because the TCA client bridge lives on the
/// main actor; the filesystem operations themselves are actor-agnostic but
/// keeping everything on MainActor simplifies the concurrency story.
@MainActor
struct GhosttyConfigFile {
  // MARK: Inputs

  let homeDirectoryURL: URL
  let environment: [String: String]
  let fileManager: FileManager
  let notificationCenter: NotificationCenter
  let catalogProvider: @MainActor () -> GhosttyThemeCatalog

  // MARK: Constants

  /// Set of directive keys this type owns. Any occurrence of these in the
  /// config file is deleted and re-emitted as a single canonical block on
  /// `apply`. v1: just `theme`; future iterations add font-family, font-size.
  private static let managedKeys: Set<String> = ["theme"]

  private static let logger = Logger(
    subsystem: "app.touch-code.mac",
    category: "appearance"
  )

  // MARK: Init

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    notificationCenter: NotificationCenter = .default,
    catalogProvider: (@MainActor () -> GhosttyThemeCatalog)? = nil
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.environment = environment
    self.fileManager = fileManager
    self.notificationCenter = notificationCenter
    // Default provider calls the reader with the same home / environment.
    // Captured values so the closure is self-contained once created.
    if let provided = catalogProvider {
      self.catalogProvider = provided
    } else {
      let capturedHome = homeDirectoryURL
      let capturedEnv = environment
      let capturedFM = fileManager
      self.catalogProvider = {
        GhosttyThemeCatalogReader.load(
          homeDirectoryURL: capturedHome,
          environment: capturedEnv,
          fileManager: capturedFM
        )
      }
    }
  }

  // MARK: - Path resolution

  /// Canonical config file: `$XDG_CONFIG_HOME/ghostty/config`, defaulting to
  /// `~/.config/ghostty/config`. One path, no candidate list — this is the
  /// file Settings reads and writes, and the one `reloadAppConfig` re-parses
  /// from disk.
  ///
  /// libghostty's `loadDefaultFiles` also probes `~/Library/Application
  /// Support/com.mitchellh.ghostty/...`, but we intentionally don't target
  /// that: writes would land in a file the user doesn't expect us to touch,
  /// and when both files exist App Support would override the XDG copy the
  /// user actually maintains. Only populate the managed region of the XDG
  /// file; let the user own whatever App Support contains.
  func resolvedConfigURL() -> URL {
    let xdgBase: URL
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      xdgBase = URL(fileURLWithPath: xdg, isDirectory: true)
    } else {
      xdgBase = homeDirectoryURL.appendingPathComponent(".config", isDirectory: true)
    }
    return
      xdgBase
      .appendingPathComponent("ghostty", isDirectory: true)
      .appendingPathComponent("config", isDirectory: false)
  }

  // MARK: - Load

  /// Read the config snapshot. Missing file → nil themes + populated catalog;
  /// a malformed `theme = <name>` (no split) → `warningMessage` set and
  /// both themes nil. Never creates files.
  func load() throws -> GhosttyTerminalSettings {
    let configURL = resolvedConfigURL()
    let catalog = catalogProvider()

    let contents: String
    if fileManager.fileExists(atPath: configURL.path) {
      do {
        contents = try String(contentsOf: configURL, encoding: .utf8)
      } catch {
        throw GhosttyConfigFileError.ioError(underlying: error)
      }
    } else {
      contents = ""
    }

    let parsed = Self.parseThemeDirective(from: contents)
    return GhosttyTerminalSettings(
      configPath: configURL.path,
      lightTheme: parsed.light,
      darkTheme: parsed.dark,
      availableLightThemes: catalog.light,
      availableDarkThemes: catalog.dark,
      themePreviews: catalog.previews,
      warningMessage: parsed.warning
    )
  }

  // MARK: - Apply

  /// Write `draft` to disk behind an atomic temp-file swap. Validates the
  /// candidate file by loading it through libghostty; if any diagnostic is
  /// raised we delete the temp file and throw without touching the original.
  /// On success, posts `.ghosttyRuntimeReloadRequested` so the live runtime
  /// reloads, then returns a fresh `load()` snapshot.
  @discardableResult
  func apply(_ draft: GhosttyTerminalSettingsDraft) throws -> GhosttyTerminalSettings {
    let configURL = resolvedConfigURL()
    let parentDir = configURL.deletingLastPathComponent()

    // Create the parent dir if missing. `withIntermediateDirectories: true`
    // is a no-op when the directory already exists.
    if !fileManager.fileExists(atPath: parentDir.path) {
      do {
        try fileManager.createDirectory(
          at: parentDir, withIntermediateDirectories: true
        )
      } catch {
        throw GhosttyConfigFileError.configDirectoryUnavailable(
          "\(parentDir.path): \(error.localizedDescription)"
        )
      }
    }

    let existing: String
    if fileManager.fileExists(atPath: configURL.path) {
      do {
        existing = try String(contentsOf: configURL, encoding: .utf8)
      } catch {
        throw GhosttyConfigFileError.ioError(underlying: error)
      }
    } else {
      existing = ""
    }

    let newContents = Self.updatedContents(from: existing, draft: draft)

    // Write to a sibling temp file so the atomic swap at the end never
    // leaves a half-written config visible to Ghostty's file-watcher.
    let tempURL = parentDir.appendingPathComponent(
      ".touch-code-ghostty-\(UUID().uuidString)",
      isDirectory: false
    )
    do {
      try newContents.write(to: tempURL, atomically: true, encoding: .utf8)
    } catch {
      throw GhosttyConfigFileError.ioError(underlying: error)
    }

    // Validate by round-tripping through libghostty.
    if let validationError = Self.validate(configURL: tempURL) {
      try? fileManager.removeItem(at: tempURL)
      throw GhosttyConfigFileError.validationFailed(validationError)
    }

    // Atomic swap: replaceItem works whether `configURL` exists or not
    // on APFS, but when it doesn't we fall back to a move.
    do {
      if fileManager.fileExists(atPath: configURL.path) {
        _ = try fileManager.replaceItemAt(configURL, withItemAt: tempURL)
      } else {
        try fileManager.moveItem(at: tempURL, to: configURL)
      }
    } catch {
      try? fileManager.removeItem(at: tempURL)
      throw GhosttyConfigFileError.ioError(underlying: error)
    }

    notificationCenter.post(name: .ghosttyRuntimeReloadRequested, object: nil)
    return try load()
  }

  // MARK: - Pure transforms (internal for tests)

  /// Remove every managed directive from `contents`, then insert a canonical
  /// managed block at the first removed position (or at end-of-file when no
  /// managed directive was present). Preserves trailing newline iff the
  /// input had one; preserves all non-managed lines verbatim.
  static func updatedContents(
    from contents: String,
    draft: GhosttyTerminalSettingsDraft
  ) -> String {
    let hadTrailingNewline = contents.hasSuffix("\n")
    // Treat empty input as zero lines rather than `[""]` so we don't insert
    // a phantom blank before the managed block on fresh files.
    let rawLines: [String]
    if contents.isEmpty {
      rawLines = []
    } else {
      rawLines = contents.components(separatedBy: "\n")
    }
    // `components(separatedBy: "\n")` on a trailing-newline input leaves a
    // phantom empty element at the end; strip it so it doesn't round-trip
    // as a double newline when we rejoin.
    let lines: [String]
    if hadTrailingNewline, let last = rawLines.last, last.isEmpty {
      lines = Array(rawLines.dropLast())
    } else {
      lines = rawLines
    }

    var kept: [String] = []
    var insertionIndex: Int?
    for line in lines {
      if let key = directiveKey(in: line), managedKeys.contains(key) {
        if insertionIndex == nil { insertionIndex = kept.count }
        continue
      }
      kept.append(line)
    }

    let managedBlock = canonicalManagedBlock(for: draft)
    var result = kept
    if !managedBlock.isEmpty {
      let at = insertionIndex ?? result.count
      // Insert all lines in order at `at`.
      result.insert(contentsOf: managedBlock, at: at)
    }

    var joined = result.joined(separator: "\n")
    if hadTrailingNewline, !joined.isEmpty, !joined.hasSuffix("\n") {
      joined.append("\n")
    }
    // Degenerate: input was empty and we inserted a managed block — append
    // a trailing newline so the file ends cleanly.
    if !hadTrailingNewline, contents.isEmpty, !managedBlock.isEmpty {
      if !joined.hasSuffix("\n") { joined.append("\n") }
    }
    return joined
  }

  /// Extract the directive key (`theme` in `theme = foo`) from a single line.
  /// Whitespace-insensitive on the left; stops at first `=`. Returns nil for
  /// comment lines, blank lines, and continuation / section markers.
  private static func directiveKey(in line: String) -> String? {
    // Match regex ^\s*([a-zA-Z0-9_-]+)\s*= manually to avoid NSRegularExpression
    // overhead on hot reparses.
    let chars = Array(line.unicodeScalars)
    var i = 0
    // Skip leading whitespace.
    while i < chars.count, CharacterSet.whitespaces.contains(chars[i]) { i += 1 }
    // Comments start with `#`.
    if i < chars.count, chars[i] == "#" { return nil }
    let keyStart = i
    while i < chars.count {
      let c = chars[i]
      let isKeyChar =
        (c >= "a" && c <= "z")
        || (c >= "A" && c <= "Z")
        || (c >= "0" && c <= "9")
        || c == "_" || c == "-"
      if !isKeyChar { break }
      i += 1
    }
    if i == keyStart { return nil }
    let key = String(String.UnicodeScalarView(chars[keyStart..<i]))
    // Skip whitespace to find `=`.
    while i < chars.count, CharacterSet.whitespaces.contains(chars[i]) { i += 1 }
    guard i < chars.count, chars[i] == "=" else { return nil }
    return key.lowercased()
  }

  /// Build the canonical managed block for `draft`. Currently emits at most
  /// one line: `theme = light:<X>,dark:<Y>`. Mirror semantics when only one
  /// theme is set.
  private static func canonicalManagedBlock(
    for draft: GhosttyTerminalSettingsDraft
  ) -> [String] {
    let light = draft.lightTheme
    let dark = draft.darkTheme
    // Resolve mirror semantics: if one side is set and the other is nil,
    // use the set side for both. Both nil → no block.
    let resolvedLight: String?
    let resolvedDark: String?
    switch (light, dark) {
    case (nil, nil):
      return []
    case (let l?, nil):
      resolvedLight = l
      resolvedDark = l
    case (nil, let d?):
      resolvedLight = d
      resolvedDark = d
    case (let l?, let d?):
      resolvedLight = l
      resolvedDark = d
    }
    guard let l = resolvedLight, let d = resolvedDark else { return [] }
    return ["theme = light:\(l),dark:\(d)"]
  }

  /// Parse the `theme = …` directive out of existing config contents, if any.
  /// Returns `(light, dark, warning)`. Non-split forms like `theme = Foo`
  /// yield a warning and nil themes so the pane prompts before overwrite.
  private static func parseThemeDirective(
    from contents: String
  ) -> (light: String?, dark: String?, warning: String?) {
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      guard directiveKey(in: line) == "theme" else { continue }
      // Extract value after `=`.
      guard let eq = line.firstIndex(of: "=") else { continue }
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      // Split form: `light:<X>,dark:<Y>` (or reversed). Each clause is
      // `key:value` and clauses are comma-separated.
      if value.contains(":") && value.contains(",") {
        var light: String?
        var dark: String?
        for clauseRaw in value.split(separator: ",") {
          let clause = clauseRaw.trimmingCharacters(in: .whitespaces)
          guard let colon = clause.firstIndex(of: ":") else { continue }
          let key = clause[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
          let name = clause[clause.index(after: colon)...].trimmingCharacters(in: .whitespaces)
          switch key {
          case "light": light = String(name)
          case "dark": dark = String(name)
          default: continue
          }
        }
        if light != nil || dark != nil {
          return (light, dark, nil)
        }
      }
      // Non-split form (e.g. `theme = Solarized`) — keep the config intact
      // but report so the UI can warn before overwrite.
      return (
        nil, nil,
        "Config file has a non-split theme directive; it will be replaced on next save"
      )
    }
    return (nil, nil, nil)
  }

  // MARK: - libghostty validation

  /// Load `configURL` into a scratch `ghostty_config_t` and collect any
  /// diagnostics. Returns nil on success (no diagnostics), or the first
  /// diagnostic message on failure. Always frees the temp config.
  private static func validate(configURL: URL) -> String? {
    guard let config = ghostty_config_new() else {
      return "could not allocate ghostty_config_t for validation"
    }
    defer { ghostty_config_free(config) }
    // Pass the temp file path. libghostty accumulates diagnostics into the
    // config object; `finalize` is what runs the structural checks.
    configURL.path.withCString { cString in
      ghostty_config_load_file(config, cString)
    }
    ghostty_config_finalize(config)
    let count = ghostty_config_diagnostics_count(config)
    guard count > 0 else { return nil }
    // Pull the first diagnostic message. Subsequent diagnostics are not
    // surfaced to the UI — one failure is enough to refuse the write.
    let diag = ghostty_config_get_diagnostic(config, 0)
    if let ptr = diag.message {
      let message = String(cString: ptr)
      logger.error("ghostty config validation failed: \(message, privacy: .public)")
      return message
    }
    return "Ghostty rejected the config (no diagnostic message available)"
  }
}
