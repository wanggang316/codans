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
  /// codans's overrides applied and finalized. Returns the config plus the
  /// user's intended `background-opacity` (captured *before* the surface
  /// override below clobbers it). Returns nil iff libghostty's allocator
  /// fails — caller decides whether that is fatal (init throws) or
  /// recoverable (reload no-ops on the previous handle). Caller owns the
  /// returned handle and must `ghostty_config_free` it.
  static func makeFreshConfig() -> (config: ghostty_config_t, userBackgroundOpacity: Double)? {
    guard let config = ghostty_config_new() else { return nil }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    applyOverrides(to: config)
    // Snapshot the user's intended background-opacity before we (conditionally)
    // clobber it; the NSWindow layer paints the frosted-glass tint at this
    // value while the surface itself is forced transparent.
    let userBackgroundOpacity = snapshotBackgroundOpacity(of: config)
    // When the terminal is translucent (opacity < 1), force the *surface* to
    // render fully transparent and let the window own the tint + blur. Keeping
    // surface alpha constant across a `background-blur` on/off toggle means
    // switching glass styles never re-renders the surface (no transparent
    // flash) and never double-applies the tint. When the user keeps the opaque
    // default we leave the surface untouched.
    if userBackgroundOpacity < 1 {
      forceTransparentSurface(config)
    }
    ghostty_config_finalize(config)
    return (config, userBackgroundOpacity)
  }

  /// Read `background-opacity` (default 1, clamped to `[0, 1]`) from a
  /// finalized *clone* of `config`. Cloning a throwaway copy lets us read a
  /// resolved value without finalizing — and thereby locking — the real
  /// config, which still needs the surface override applied.
  private static func snapshotBackgroundOpacity(of config: ghostty_config_t) -> Double {
    guard let clone = ghostty_config_clone(config) else { return 1 }
    defer { ghostty_config_free(clone) }
    ghostty_config_finalize(clone)
    var value: Double = 1
    let key = "background-opacity"
    _ = ghostty_config_get(clone, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    return min(max(value, 0), 1)
  }

  /// Load a `background-opacity = 0` override so the libghostty surface renders
  /// fully transparent. Last-write-wins clobbers the user's value in the live
  /// config; the original is preserved separately (see
  /// `snapshotBackgroundOpacity`) for the window-layer tint. Silent no-op on
  /// write failure.
  private static func forceTransparentSurface(_ config: ghostty_config_t) {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ghostty-transparent-surface.conf")
    do {
      try "background-opacity = 0\n".write(to: url, atomically: true, encoding: .utf8)
    } catch {
      logger.error(
        "could not write surface-opacity override at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return
    }
    url.path.withCString { ghostty_config_load_file(config, $0) }
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
