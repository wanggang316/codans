import AppKit

/// Process-lifetime cache for the app icons rendered beside editor names in
/// menus, sidebar context menus, and the Worktree-header open button.
///
/// macOS SwiftUI evaluates `Menu` / `.contextMenu` content eagerly on every
/// body evaluation of the hosting row. Uncached, each evaluation paid a
/// `NSWorkspace.icon(forFile:)` LaunchServices query plus an offscreen
/// `lockFocus` redraw per editor per row. With a dozen installed editors
/// across every sidebar worktree row, a single agent-state invalidation
/// stalled the main thread for hundreds of milliseconds — and right after an
/// app update, when LaunchServices re-registers the replaced bundle and each
/// query takes the slow registration path, the same re-render storm wedged
/// launch for minutes (fix/update-loading-long).
///
/// An icon is immutable for a given (path, side) over a process lifetime, so
/// a plain dictionary suffices. `clear()` is wired to
/// `EditorClient.clearCache` alongside the `describe()` cache so a freshly
/// installed or updated editor surfaces its new icon without a restart.
@MainActor
enum EditorAppIcons {
  /// Redrawn icons keyed by `"<path>#<side>"`.
  private static var resizedByPath: [String: NSImage] = [:]
  /// Bundle-id → app URL. Negative results are cached too: a bundle id that
  /// resolves to no URL would otherwise re-probe LaunchServices on every
  /// render of the fallback glyph.
  private static var urlByBundleID: [String: URL?] = [:]

  /// Launch Services lookup of an app's URL by bundle identifier, cached
  /// (including the not-installed answer).
  static func appURL(bundleIdentifier: String) -> URL? {
    guard !bundleIdentifier.isEmpty else { return nil }
    if let cached = urlByBundleID[bundleIdentifier] { return cached }
    let resolved = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: bundleIdentifier
    )
    urlByBundleID[bundleIdentifier] = resolved
    return resolved
  }

  /// A `side`×`side` redraw of the app icon at `path`, cached per
  /// (path, side). The redraw exists because AppKit reads an `NSImage`'s
  /// intrinsic size when bridging SwiftUI rows into `NSMenuItem`; the
  /// source icon's native ~256pt representation would stretch menu rows.
  static func resizedIcon(atPath path: String, side: CGFloat) -> NSImage {
    let key = "\(path)#\(Int(side))"
    if let cached = resizedByPath[key] { return cached }

    let source = NSWorkspace.shared.icon(forFile: path)
    let target = NSSize(width: side, height: side)
    let resized = NSImage(size: target)
    resized.lockFocus()
    source.draw(
      in: NSRect(origin: .zero, size: target),
      from: NSRect(origin: .zero, size: source.size),
      operation: .sourceOver,
      fraction: 1.0
    )
    resized.unlockFocus()
    resizedByPath[key] = resized
    return resized
  }

  /// Drops every cached icon and bundle-id resolution. Called on the same
  /// path that invalidates `LiveEditorService`'s descriptor cache, so the
  /// next `describe()` re-resolves URLs and the next render re-draws icons
  /// for whatever is now installed.
  static func clear() {
    resizedByPath.removeAll()
    urlByBundleID.removeAll()
  }
}
