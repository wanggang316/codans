import Foundation

/// On-disk home for custom Project icons: `<config>/project-icons/`.
///
/// Picking a custom icon **copies** the artwork here under a fresh UUID name
/// rather than remembering where the user found it. Two reasons: the Project
/// keeps its icon when the original is moved, renamed or deleted, and the
/// catalog stores a bare file name instead of an absolute path that would
/// leak a home directory into a file the user may well commit.
///
/// The UUID name is also what makes caching safe downstream — replacing an
/// icon always yields a new file name, so a renderer may cache decoded images
/// by name without watching the file for changes.
public nonisolated enum ProjectIconStore {
  public enum ImportError: Error, Equatable {
    /// The picked file's extension is not in `ProjectIcon.supportedExtensions`.
    case unsupportedFormat(String)
  }

  /// `<config>/project-icons/`. Not created here — `importIcon` creates it on
  /// the first write so a user who never picks a custom icon gets no directory.
  public static func directory(
    configDirectory: URL = AppDirectories.configDirectory()
  ) -> URL {
    configDirectory.appendingPathComponent("project-icons", isDirectory: true)
  }

  /// Resolves the stored file name of a `.custom` icon back to a URL.
  public static func fileURL(
    for fileName: String,
    configDirectory: URL = AppDirectories.configDirectory()
  ) -> URL {
    directory(configDirectory: configDirectory).appendingPathComponent(fileName)
  }

  /// Copies `sourceURL` into the icon directory and returns the stored file
  /// name to persist on `Project.icon`. Throws `unsupportedFormat` for an
  /// extension the renderer can't decode, so a bad pick is reported at the
  /// picker instead of silently rendering as a blank slot forever.
  @discardableResult
  public static func importIcon(
    from sourceURL: URL,
    configDirectory: URL = AppDirectories.configDirectory(),
    fileManager: FileManager = .default
  ) throws -> String {
    let ext = ProjectIcon.normalizedExtension(of: sourceURL.lastPathComponent)
    guard ProjectIcon.supportedExtensions.contains(ext) else {
      throw ImportError.unsupportedFormat(ext)
    }
    let directory = directory(configDirectory: configDirectory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileName = "\(UUID().uuidString).\(ext)"
    try fileManager.copyItem(at: sourceURL, to: directory.appendingPathComponent(fileName))
    return fileName
  }

  /// Best-effort delete of a custom icon file that nothing references any
  /// more. Failures are swallowed: an orphaned icon file is inert, whereas
  /// throwing here would fail the catalog write that already succeeded.
  public static func removeIcon(
    named fileName: String,
    configDirectory: URL = AppDirectories.configDirectory(),
    fileManager: FileManager = .default
  ) {
    try? fileManager.removeItem(
      at: fileURL(for: fileName, configDirectory: configDirectory)
    )
  }
}
