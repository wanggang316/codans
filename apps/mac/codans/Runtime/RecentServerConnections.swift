import CodansCore
import Foundation

/// Most-recently-used list of validated Server connections, kept beside the
/// catalog as `recent-connections.json`. Feeds the "Connect to Server"
/// sheet's Recent menu so a previously used host + path is one click away
/// instead of retyped. Connection info only — never a credential (auth stays
/// in the user's SSH config + agent).
nonisolated enum RecentServerConnections {
  struct Entry: Codable, Hashable, Sendable {
    var host: RemoteHost
    var path: String
  }

  /// MRU cap so the menu stays scannable.
  static let maxEntries = 8

  static func defaultURL() -> URL {
    Catalog.defaultURL().deletingLastPathComponent()
      .appendingPathComponent("recent-connections.json", isDirectory: false)
  }

  /// Most-recently-used first. Missing or unreadable file reads as empty.
  static func read(at url: URL = defaultURL()) -> [Entry] {
    (try? AtomicFileStore.read([Entry].self, at: url)) ?? []
  }

  /// Move-or-insert `(host, path)` to the front and persist. Identity is the
  /// full pair — the same host with two project paths keeps two entries, so a
  /// pick always fills every field of the form.
  static func record(host: RemoteHost, path: String, at url: URL = defaultURL()) {
    var entries = read(at: url)
    let entry = Entry(host: host, path: path)
    entries.removeAll { $0 == entry }
    entries.insert(entry, at: 0)
    if entries.count > maxEntries {
      entries.removeLast(entries.count - maxEntries)
    }
    try? AtomicFileStore.write(entries, to: url)
  }
}
