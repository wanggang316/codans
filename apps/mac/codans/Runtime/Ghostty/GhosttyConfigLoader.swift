import Foundation
import GhosttyKit
import os.log

/// Single owner of the "build a fresh ghostty_config_t" sequence — wraps
/// `ghostty_config_new` + the user-config loads + codans's overrides +
/// `ghostty_config_finalize` so every site that rebuilds a config goes
/// through one code path (initial bring-up, app-level hard reload,
/// per-surface hard reload). Without this collapse the overrides apply
/// step is easy to forget at a new call site.
///
/// Overrides win because libghostty's loader resolves last-write-wins —
/// `applyOverrides` runs after the user's default + recursive files, so
/// any directive in `overridesBody` clobbers the corresponding entry in
/// the user's `~/.config/ghostty/config`.
///
/// The only override today removes Ghostty's default
/// `super+enter → toggle_fullscreen` keybind so `⌘⏎` falls through to the
/// inner program. Add new lines to `overridesBody` as more codans
/// overrides land.
enum GhosttyConfigLoader {
  /// Build a fresh `ghostty_config_t` with the user's config files +
  /// codans's overrides applied and finalized. Returns nil iff
  /// libghostty's allocator fails — caller decides whether that is fatal
  /// (init throws) or recoverable (reload no-ops on the previous handle).
  /// Caller owns the returned handle and must `ghostty_config_free` it.
  static func makeFreshConfig() -> ghostty_config_t? {
    guard let config = ghostty_config_new() else { return nil }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    applyOverrides(to: config)
    ghostty_config_finalize(config)
    return config
  }

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.mac",
    category: "ghostty.config"
  )

  /// Body of the overrides file. Every line is a libghostty config
  /// directive; `keybind = <chord>=unbind` removes a previously-registered
  /// binding.
  private static let overridesBody: String = """
    # codans overrides — managed automatically; do not edit.
    # Removes the default ⌘⏎ fullscreen keybind.
    keybind = super+enter=unbind

    """

  /// Materialise `overridesBody` as a temp file and ask libghostty to load
  /// it on top of the supplied config. Silent no-op on write failure — the
  /// runtime still works, the user just keeps the stock keybinds.
  private static func applyOverrides(to config: ghostty_config_t) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ghostty-overrides.conf")
    do {
      try overridesBody.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      logger.error(
        "could not write overrides file at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return
    }
    url.path.withCString { ghostty_config_load_file(config, $0) }
  }
}
