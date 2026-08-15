import CodansCore
import Foundation

/// Most-recently-used list of successfully validated server hosts (address +
/// username + port), kept beside the catalog as `saved-server-hosts.json`.
/// Feeds the Connect to Server sheet's host-field picker so a known server's
/// connection info is one click away instead of retyped. Connection info
/// only — never a credential (auth stays in the user's SSH config + agent).
nonisolated enum SavedServerHosts {
  /// MRU cap so the picker stays scannable.
  static let maxEntries = 8

  static func defaultURL() -> URL {
    Catalog.defaultURL().deletingLastPathComponent()
      .appendingPathComponent("saved-server-hosts.json", isDirectory: false)
  }

  /// Most-recently-used first. Missing or unreadable file reads as empty.
  static func read(at url: URL = defaultURL()) -> [RemoteHost] {
    (try? AtomicFileStore.read([RemoteHost].self, at: url)) ?? []
  }

  /// Move-or-insert `host` to the front and persist. Identity is the full
  /// (address, username, port) triple — the same machine reached as two
  /// different users or ports keeps distinct entries.
  static func record(_ host: RemoteHost, at url: URL = defaultURL()) {
    var hosts = read(at: url)
    hosts.removeAll { $0 == host }
    hosts.insert(host, at: 0)
    if hosts.count > maxEntries {
      hosts.removeLast(hosts.count - maxEntries)
    }
    try? AtomicFileStore.write(hosts, to: url)
  }
}
