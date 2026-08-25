import Foundation

/// Atomic-rename JSON read/write helper. `write` encodes to a sibling temp file in the target
/// directory, `fsync`s it, then `rename(2)`s over the original — so a crash mid-write leaves the
/// previous file intact. `read` returns nil on missing file; other I/O and decode errors throw.
///
/// When the destination is a symlink (users commonly link `~/.config/codans/*.json` into a
/// dotfiles repository), `write` resolves the link chain first and renames over the *target*,
/// so the link survives instead of being replaced by a regular file.
///
/// Callers are responsible for version checks on the decoded value; this helper deliberately
/// does not interpret payloads. It only guarantees the file-system atomicity story.
public nonisolated enum AtomicFileStore {
  public enum Failure: Error, Equatable {
    case createDirectoryFailed(path: String, code: Int32)
    case temporaryWriteFailed(path: String, code: Int32)
    case renameFailed(from: String, to: String, code: Int32)
    case fsyncFailed(path: String, code: Int32)
    case tooManySymlinks(path: String)
  }

  public static func read<T: Decodable>(
    _ type: T.Type,
    at url: URL,
    decoder: JSONDecoder = .touchCodeDefault
  ) throws -> T? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    return try decoder.decode(T.self, from: data)
  }

  public static func write<T: Encodable>(
    _ value: T,
    to url: URL,
    encoder: JSONEncoder = .touchCodeDefault
  ) throws {
    let data = try encoder.encode(value)
    let destination = try resolvingSymlinks(at: url)
    let directory = destination.deletingLastPathComponent()
    try ensureDirectory(directory)

    // Temp file lives next to the resolved target so the rename stays on one file system.
    let tempURL = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
    do {
      try writeAndFsync(data: data, to: tempURL)
    } catch {
      // `open` may have succeeded before `write`/`fsync` hit ENOSPC, leaving a
      // partial (often zero-byte) temp file next to the target. Without this
      // cleanup every failed save leaks one, so a full disk accumulates litter
      // in the very directory it cannot spare bytes in.
      _ = try? FileManager.default.removeItem(at: tempURL)
      throw error
    }

    let renameResult = rename(tempURL.path, destination.path)
    if renameResult != 0 {
      // Best-effort cleanup of the temp file on rename failure; ignore secondary errors.
      _ = try? FileManager.default.removeItem(at: tempURL)
      throw Failure.renameFailed(from: tempURL.path, to: destination.path, code: errno)
    }
  }

  /// Follows the symlink chain at `url`'s final path component. Unlike `resolvingSymlinksInPath()`
  /// this also resolves *dangling* links (target not yet created — e.g. a fresh dotfiles checkout),
  /// so the first write lands at the link's target instead of replacing the link itself.
  private static func resolvingSymlinks(at url: URL) throws -> URL {
    let fm = FileManager.default
    var resolved = url.standardizedFileURL
    var hops = 0
    while let target = try? fm.destinationOfSymbolicLink(atPath: resolved.path) {
      hops += 1
      if hops > maxSymlinkHops { throw Failure.tooManySymlinks(path: url.path) }
      if target.hasPrefix("/") {
        resolved = URL(fileURLWithPath: target)
      } else {
        resolved =
          resolved
          .deletingLastPathComponent()
          .appendingPathComponent(target)
          .standardizedFileURL
      }
    }
    return resolved
  }

  /// Mirrors the kernel's SYMLOOP_MAX (32 on Darwin) as a loop guard.
  private static let maxSymlinkHops = 32

  private static func ensureDirectory(_ url: URL) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return }
    do {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw Failure.createDirectoryFailed(path: url.path, code: errno)
    }
  }

  private static func writeAndFsync(data: Data, to url: URL) throws {
    // Open with O_CREAT|O_WRONLY|O_TRUNC, 0o600. Deliberately private-by-default — user data.
    let fd = url.path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o600) }
    if fd < 0 { throw Failure.temporaryWriteFailed(path: url.path, code: errno) }
    defer { _ = close(fd) }

    var remaining = data
    while !remaining.isEmpty {
      let written = remaining.withUnsafeBytes { buf -> ssize_t in
        guard let base = buf.baseAddress else { return 0 }
        return Darwin.write(fd, base, buf.count)
      }
      if written < 0 { throw Failure.temporaryWriteFailed(path: url.path, code: errno) }
      remaining = remaining.advanced(by: Int(written))
    }

    if Darwin.fsync(fd) != 0 { throw Failure.fsyncFailed(path: url.path, code: errno) }
  }
}

extension JSONEncoder {
  public static var touchCodeDefault: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  public static var touchCodeDefault: JSONDecoder { JSONDecoder() }
}

extension Data {
  fileprivate func advanced(by count: Int) -> Data {
    guard count > 0, count <= self.count else { return self }
    return self.subdata(in: count..<self.count)
  }
}
