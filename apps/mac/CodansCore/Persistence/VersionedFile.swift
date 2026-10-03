import Foundation

/// On-disk shape for a store whose payload has no room for a version field of
/// its own (a bare map or list): `{ "version": N, "entries": … }`.
public nonisolated struct VersionedEnvelope<Entries: Codable & Sendable>: Codable, Sendable {
  public var version: Int
  public var entries: Entries

  public init(version: Int, entries: Entries) {
    self.version = version
    self.entries = entries
  }
}

/// Read / write for small best-effort stores kept in a `VersionedEnvelope`
/// (`remote-hosts.json`, `saved-server-hosts.json`, `github-snapshots.json`).
///
/// A file this build cannot read — corrupt, or from a newer version — is
/// handled per `Unreadable` *before* anything is returned, so the caller's
/// next write can never destroy data a newer build still understands.
public nonisolated enum VersionedFile {
  public enum Unreadable: Sendable {
    /// Move the file into `backups/` (state the user may want back).
    case backUp
    /// Delete it (a cache that refills itself).
    case discard
  }

  public enum LoadResult<Entries> {
    /// Decoded entries, or `empty` for a missing or set-aside file. Safe to write.
    case loaded(Entries)
    /// Unreadable and still in place (the backup failed). Must not write.
    case locked
  }

  /// - Parameters:
  ///   - legacy: decodes the pre-envelope bare shape, if the store had one;
  ///     the next `write` upgrades the file.
  public static func load<Entries: Codable & Sendable>(
    _ type: Entries.Type,
    at url: URL,
    currentVersion: Int,
    empty: Entries,
    unreadable: Unreadable,
    legacy: ((Data) throws -> Entries)? = nil,
    fileManager: FileManager = .default
  ) -> LoadResult<Entries> {
    guard fileManager.fileExists(atPath: url.path) else { return .loaded(empty) }
    guard let data = try? Data(contentsOf: url) else { return .locked }

    let decoder = JSONDecoder.touchCodeDefault
    let reason: StoreBackup.Reason
    // Probe the version alone first: a newer build may have changed the
    // entries' shape, and that must read as "newer", not "corrupt".
    if let probe = try? decoder.decode(VersionProbe.self, from: data), probe.version > currentVersion {
      reason = .unsupported(version: probe.version)
    } else if let envelope = try? decoder.decode(VersionedEnvelope<Entries>.self, from: data) {
      return .loaded(envelope.entries)
    } else if let legacy, let entries = try? legacy(data) {
      return .loaded(entries)
    } else {
      reason = .corrupt
    }

    switch unreadable {
    case .backUp:
      guard (try? StoreBackup.moveAside(url, reason: reason, fileManager: fileManager)) != nil else {
        return .locked
      }
    case .discard:
      guard (try? fileManager.removeItem(at: url)) != nil else { return .locked }
    }
    return .loaded(empty)
  }

  private struct VersionProbe: Decodable {
    let version: Int
  }

  public static func write<Entries: Codable & Sendable>(
    _ entries: Entries,
    to url: URL,
    version: Int
  ) throws {
    try AtomicFileStore.write(VersionedEnvelope(version: version, entries: entries), to: url)
  }
}
