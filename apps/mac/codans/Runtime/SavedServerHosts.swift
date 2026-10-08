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

  /// Envelope version. v0 was a bare `[RemoteHost]` array, still read.
  static let currentVersion = 1

  static func defaultURL() -> URL {
    Catalog.defaultURL().deletingLastPathComponent()
      .appendingPathComponent("saved-server-hosts.json", isDirectory: false)
  }

  /// Most-recently-used first. Missing or unreadable file reads as empty.
  static func read(at url: URL = defaultURL()) -> [RemoteHost] {
    load(at: url) ?? []
  }

  /// `nil` when the file is unreadable and could not be backed up.
  private static func load(at url: URL) -> [RemoteHost]? {
    let result = VersionedFile.load(
      [RemoteHost].self, at: url, currentVersion: currentVersion, empty: [], unreadable: .backUp,
      legacy: { try JSONDecoder.touchCodeDefault.decode([RemoteHost].self, from: $0) }
    )
    switch result {
    case .loaded(let hosts): return hosts
    case .locked: return nil
    }
  }

  /// Move-or-insert `host` to the front and persist. Identity is the full
  /// (address, username, port) triple — the same machine reached as two
  /// different users or ports keeps distinct entries.
  static func record(_ host: RemoteHost, at url: URL = defaultURL()) {
    guard var hosts = load(at: url) else { return }
    hosts.removeAll { $0 == host }
    hosts.insert(host, at: 0)
    if hosts.count > maxEntries {
      hosts.removeLast(hosts.count - maxEntries)
    }
    try? VersionedFile.write(hosts, to: url, version: currentVersion)
  }
}
