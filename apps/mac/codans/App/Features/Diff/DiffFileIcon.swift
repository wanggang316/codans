import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Type-based icons also work for deleted files and remote worktrees, without disk access.
///
/// Symbols rather than `NSWorkspace.icon(for:)`, which hands back the icon of whichever app is
/// registered for the type: with IDEs installed, `.java` rows showed the IntelliJ icon and `.tsx`,
/// `.go` and `.cs` all showed the GoLand one, which says nothing about the file.
@MainActor
struct DiffFileIcon: View {
  let path: String

  var body: some View {
    Image(systemName: Self.symbolName(for: path))
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .frame(width: 16, height: 16)
      .accessibilityHidden(true)
  }

  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
  }()

  /// The template image for the same symbol, for AppKit rows.
  static func image(for path: String) -> NSImage? {
    let name = symbolName(for: path) as NSString
    if let image = cache.object(forKey: name) { return image }
    let image = NSImage(systemSymbolName: name as String, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
    if let image { cache.setObject(image, forKey: name) }
    return image
  }

  /// Extensions macOS does not classify as source code — it knows nothing about Go or Rust, and
  /// whichever editor is installed may claim them as plain data.
  private static let codeExtensions: Set<String> = [
    "c", "cc", "cjs", "clj", "cpp", "cs", "css", "cxx", "dart", "elm", "erl", "ex", "exs", "fs", "go",
    "gradle", "graphql", "h", "hpp", "hs", "htm", "html", "java", "jl", "js", "json", "jsx", "kt",
    "kts", "lua", "m", "mjs", "mm", "nim", "php", "pl", "proto", "py", "r", "rb", "rs", "sass",
    "scala", "scss", "sh", "sql", "svelte", "swift", "tf", "toml", "ts", "tsx", "vue", "xml", "yaml",
    "yml", "zig", "zsh",
  ]

  static func symbolName(for path: String) -> String {
    let name = (path as NSString).lastPathComponent
    let ext = (name as NSString).pathExtension.lowercased()
    if codeExtensions.contains(ext) { return "curlybraces" }
    // No extension: dotfiles, Makefile, Dockerfile and the like are all text.
    guard let type = UTType(filenameExtension: ext) else { return "doc.text" }
    if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "curlybraces" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .database) || type.conforms(to: .spreadsheet) { return "tablecells" }
    if type.conforms(to: .executable) || type.conforms(to: .unixExecutable) { return "gearshape" }
    // A diff shows text, so anything left reads as a document rather than as unknown data.
    return "doc.text"
  }
}
