import AppKit
import SwiftUI
import CodansCore

/// Manages user-uploaded custom command icons. A `ScriptDefinition` stores only
/// a bare filename in `customIconPath`; the actual image lives under
/// `~/.config/codans/command-icons/` so `settings.json` stays portable and the
/// app owns the copy (the user's original file can move or be deleted without
/// breaking the command).
///
/// MainActor-isolated: every caller is a SwiftUI view body or a popover action,
/// so the in-memory cache needs no extra synchronization.
@MainActor
enum CommandIconStore {
  /// `~/.config/codans/command-icons/` — managed store for uploaded icons.
  static func directory() -> URL {
    AppDirectories.configDirectory()
      .appendingPathComponent("command-icons", isDirectory: true)
  }

  static func url(for filename: String) -> URL {
    directory().appendingPathComponent(filename)
  }

  /// Copy a user-selected image into the managed directory under a fresh UUID
  /// filename (extension preserved) and return that filename. The caller stores
  /// the returned value in `ScriptDefinition.customIconPath`.
  static func importImage(from source: URL) throws -> String {
    let dir = directory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Honour security-scoped access for sandboxed builds; a no-op otherwise.
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
    let filename = UUID().uuidString + "." + ext
    try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(filename))
    return filename
  }

  /// Best-effort delete of a managed icon file plus its cache entry. Called when
  /// the user replaces or clears a command's custom icon.
  static func remove(filename: String) {
    cache.removeObject(forKey: filename as NSString)
    try? FileManager.default.removeItem(at: url(for: filename))
  }

  private static let cache = NSCache<NSString, NSImage>()

  /// Loads (and memoizes) the managed icon. Returns `nil` when the file is
  /// missing or unreadable — callers fall back to the SF Symbol.
  static func image(for filename: String) -> NSImage? {
    if let cached = cache.object(forKey: filename as NSString) { return cached }
    guard let image = NSImage(contentsOf: url(for: filename)) else { return nil }
    cache.setObject(image, forKey: filename as NSString)
    return image
  }

  /// A square, non-template `NSImage` sized for a native `NSMenu` item. Native
  /// menu items render their icon as a monochrome template and strip SwiftUI
  /// styling, so the custom image is redrawn at the requested point size with
  /// `isTemplate = false` to survive into the menu (mirrors
  /// `ScriptTintColorPalette.menuIcon`).
  static func menuImage(for filename: String, size: CGFloat = 14) -> Image? {
    guard let source = image(for: filename) else { return nil }
    let target = NSImage(size: NSSize(width: size, height: size))
    target.lockFocus()
    source.draw(
      in: NSRect(x: 0, y: 0, width: size, height: size),
      from: .zero, operation: .sourceOver, fraction: 1
    )
    target.unlockFocus()
    target.isTemplate = false
    return Image(nsImage: target)
  }
}

/// Renders a `ScriptDefinition`'s icon: the user's custom image when set and
/// loadable, otherwise the resolved SF Symbol tinted with the command's colour.
/// Shared by the command table and any other SwiftUI surface that shows a
/// command glyph.
@MainActor
struct ScriptIconView: View {
  let script: ScriptDefinition
  var size: CGFloat = 16

  var body: some View {
    if let filename = script.customIconPath, let image = CommandIconStore.image(for: filename) {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      Image(systemName: script.resolvedSystemImage)
        .foregroundStyle(ScriptTintColorPalette.color(for: script.resolvedTintColor))
        .frame(width: size, alignment: .center)
        .accessibilityHidden(true)
    }
  }
}
