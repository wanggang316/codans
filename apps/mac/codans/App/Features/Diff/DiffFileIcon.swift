import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Type-based icons also work for deleted files and remote worktrees, without disk access.
@MainActor
struct DiffFileIcon: View {
  let path: String
  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 128
    return cache
  }()

  var body: some View {
    Image(nsImage: Self.image(for: path)).resizable().interpolation(.high)
      .frame(width: 16, height: 16).accessibilityHidden(true)
  }

  static func image(for path: String) -> NSImage {
    let name = (path as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    let type = UTType(filenameExtension: ext) ?? (name.hasPrefix(".") ? .plainText : .data)
    let key = type.identifier as NSString
    if let image = cache.object(forKey: key) { return image }
    let image = NSWorkspace.shared.icon(for: type)
    cache.setObject(image, forKey: key)
    return image
  }
}
