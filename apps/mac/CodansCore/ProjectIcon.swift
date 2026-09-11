import Foundation

/// Per-Project glyph shown wherever a Project is listed — the main sidebar's
/// Project header row, the Settings sidebar, the manual-reorder sheet.
///
/// `nil` on `Project.icon` means "no choice made" and renders the built-in
/// folder pair: `folder` while the Project is collapsed, `folder.fill` while
/// it is expanded. SF Symbols ships no open-folder glyph, so the filled
/// variant is what carries the "open" reading.
///
/// Codable shape is a single prefix-tagged string so the catalog stays
/// diff-friendly and a future case can be added without colliding with an
/// existing value:
/// - `.symbol("terminal")` → `"sf:terminal"`
/// - `.custom(fileName: "A1B2.svg")` → `"file:A1B2.svg"`
///
/// A custom icon stores only the *file name*, never a path: the file itself
/// is copied into `ProjectIconStore.directory` at pick time, so moving or
/// deleting the user's original never breaks the Project.
public nonisolated enum ProjectIcon: Equatable, Hashable, Sendable {
  /// An SF Symbol name. Always tinted by the Project color.
  case symbol(String)
  /// File name (not a path) inside `ProjectIconStore.directory`.
  case custom(fileName: String)

  /// Glyph used when `Project.icon` is `nil` and the Project is collapsed.
  public static let defaultCollapsedSymbol = "folder"
  /// Glyph used when `Project.icon` is `nil` and the Project is expanded.
  public static let defaultExpandedSymbol = "folder.fill"

  /// Image formats a custom icon may be imported from. Vector entries are
  /// the recolorable ones — see `tintableExtensions`.
  public static let supportedExtensions: Set<String> = [
    "svg", "pdf", "png", "jpg", "jpeg", "heic", "tiff", "gif", "icns",
  ]

  /// Extensions whose artwork is single-color vector line work, so the
  /// Project color can repaint it via template rendering. Raster formats
  /// carry their own palette and are drawn as-is — repainting a photo or a
  /// multi-color PNG as a silhouette loses the picture rather than tinting it.
  public static let tintableExtensions: Set<String> = ["svg", "pdf"]

  /// Whether the Project color should repaint this icon. SF Symbols always
  /// follow the color; custom artwork only does so for vector formats.
  public var followsProjectColor: Bool {
    switch self {
    case .symbol:
      return true
    case .custom(let fileName):
      return Self.tintableExtensions.contains(Self.normalizedExtension(of: fileName))
    }
  }

  /// The backing file name when this is a custom icon, `nil` for a symbol.
  /// Lets callers clean up the on-disk file when the icon is replaced.
  public var customFileName: String? {
    guard case .custom(let fileName) = self else { return nil }
    return fileName
  }

  /// Lower-cased path extension, with no leading dot. Isolated so the
  /// import guard and the tint rule agree on what "the extension" means.
  public static func normalizedExtension(of fileName: String) -> String {
    (fileName as NSString).pathExtension.lowercased()
  }
}

extension ProjectIcon: Codable {
  private static let symbolPrefix = "sf:"
  private static let customPrefix = "file:"

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    if raw.hasPrefix(Self.symbolPrefix) {
      let name = String(raw.dropFirst(Self.symbolPrefix.count))
      guard !name.isEmpty else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Empty SF Symbol name in ProjectIcon"
        )
      }
      self = .symbol(name)
      return
    }
    if raw.hasPrefix(Self.customPrefix) {
      let fileName = String(raw.dropFirst(Self.customPrefix.count))
      // Reject anything that isn't a bare file name — a stored path would let
      // a hand-edited catalog point the renderer outside the icon directory.
      guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Invalid custom icon file name: \(fileName)"
        )
      }
      self = .custom(fileName: fileName)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Unknown ProjectIcon value: \(raw)"
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .symbol(let name):
      try container.encode(Self.symbolPrefix + name)
    case .custom(let fileName):
      try container.encode(Self.customPrefix + fileName)
    }
  }
}
