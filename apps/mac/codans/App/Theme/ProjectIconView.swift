import AppKit
import CodansCore
import SwiftUI

/// The one place a `Project.icon` turns into pixels. Shared by the main
/// sidebar's Project header row, the Settings sidebar, the manual-reorder
/// sheet, and the Icon picker's own preview, so every surface agrees on the
/// default glyph, the sizing, and the tint rule.
///
/// Tint rule: SF Symbols always take the Project color; custom
/// artwork only does so for vector formats, which are single-color line work
/// that template rendering repaints cleanly. Raster artwork carries its own
/// palette and is drawn as-is — flattening a multi-color PNG to a silhouette
/// destroys the picture rather than tinting it.
struct ProjectIconView: View {
  let icon: ProjectIcon?
  let color: ProjectColor?
  var size: CGFloat = 13
  /// Tint used when the Project carries no color of its own.
  var fallbackTint: Color = .secondary
  /// Glyph drawn when the Project has picked no icon. Callers that know the
  /// Project pass `defaultSymbol(for:)` so a workspace reads as a stack of
  /// checkouts rather than a folder; the plain default keeps previews and
  /// pickers folder-shaped.
  var defaultSymbol: String = ProjectIconView.folderSymbol

  var body: some View {
    content
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  /// Glyph for a Project that has picked no icon of its own. Fixed, not a
  /// pair: SF Symbols has no open-folder glyph, `folder.fill` reads as
  /// "selected" rather than "open", and a hand-drawn substitute is not worth
  /// maintaining against the system set.
  static let folderSymbol = "folder"
  /// Workspace roots are a folder of checkouts, not a repository, so they get
  /// their own default glyph; a user-picked icon still wins.
  static let workspaceSymbol = "square.stack.3d.up"

  static func defaultSymbol(for kind: ProjectKind) -> String {
    kind == .workspace ? workspaceSymbol : folderSymbol
  }

  @ViewBuilder
  private var content: some View {
    switch icon {
    case .none:
      symbolImage(named: defaultSymbol)
    case .symbol(let name):
      symbolImage(named: name)
    case .custom(let fileName):
      if let image = ProjectIconImageCache.image(forFileName: fileName) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .renderingMode(followsProjectColor ? .template : .original)
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(tint)
          .accessibilityHidden(true)
      } else {
        // The file is gone (hand-deleted config directory, a half-restored
        // backup). Show the default glyph rather than an empty slot so the
        // row keeps its shape and stays clickable.
        symbolImage(named: defaultSymbol)
      }
    }
  }

  private func symbolImage(named name: String) -> some View {
    Image(systemName: name)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(tint)
      .accessibilityHidden(true)
  }

  private var followsProjectColor: Bool {
    icon?.followsProjectColor ?? true
  }

  private var tint: Color {
    color?.swiftUIColor ?? fallbackTint
  }
}

/// Decoded-image cache for custom Project icons, keyed by file name.
///
/// Safe to cache without watching the filesystem: `ProjectIconStore` stamps a
/// fresh UUID file name on every import, so a name never changes contents —
/// replacing an icon produces a new key and the old entry simply goes cold.
/// A miss is cached as well, so a Project whose artwork was deleted out from
/// under it doesn't hit the disk on every sidebar repaint.
@MainActor
enum ProjectIconImageCache {
  private static var entries: [String: NSImage?] = [:]

  static func image(forFileName fileName: String) -> NSImage? {
    if let cached = entries[fileName] { return cached }
    let url = ProjectIconStore.fileURL(for: fileName)
    let image = NSImage(contentsOf: url)
    // Template flagging is what lets AppKit-backed artwork honor
    // `foregroundStyle`; SwiftUI's `.renderingMode` alone does not reach
    // into an `NSImage`'s own representations.
    image?.isTemplate = ProjectIcon.tintableExtensions.contains(
      ProjectIcon.normalizedExtension(of: fileName)
    )
    entries[fileName] = image
    return image
  }

  /// Drops a single entry so a freshly imported file is re-read. Import
  /// always produces a new name, so this exists only for the picker's
  /// re-pick-the-same-artwork path.
  static func invalidate(fileName: String) {
    entries.removeValue(forKey: fileName)
  }
}
