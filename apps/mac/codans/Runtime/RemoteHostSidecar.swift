import CodansCore
import Foundation

/// Self-healing store for Server projects' connection info, kept beside the
/// catalog as `remote-hosts.json` (project-id → `RemoteHost`).
///
/// The dev catalog is shared by every branch's Debug build. A build predating
/// `Project.remoteHost` decodes tolerantly, drops the unknown key, and its
/// next save silently demotes a Server project to a broken "local" one whose
/// rootPath exists only on the host. Older builds don't know this sidecar, so
/// they can't strip it — on the next launch of a current build, any project
/// whose `remoteHost` is missing but whose id has a sidecar entry gets its
/// connection restored and re-persisted.
nonisolated enum RemoteHostSidecar {
  /// id-raw-UUID-string → host. String keys keep the file greppable and the
  /// codable shape trivial.
  typealias Entries = [String: RemoteHost]

  /// Envelope version. v0 was the bare `Entries` map, still read.
  static let currentVersion = 1

  static func url(alongsideCatalogAt catalogURL: URL) -> URL {
    catalogURL.deletingLastPathComponent()
      .appendingPathComponent("remote-hosts.json", isDirectory: false)
  }

  /// `nil` when the file is unreadable and could not be backed up — callers
  /// must then leave it alone.
  static func load(at url: URL) -> Entries? {
    let result = VersionedFile.load(
      Entries.self, at: url, currentVersion: currentVersion, empty: [:], unreadable: .backUp,
      legacy: { try JSONDecoder.touchCodeDefault.decode(Entries.self, from: $0) }
    )
    switch result {
    case .loaded(let entries): return entries
    case .locked: return nil
    }
  }

  static func read(at url: URL) -> Entries {
    load(at: url) ?? [:]
  }

  /// Restore stripped `remoteHost`s from the sidecar. Only fills projects
  /// whose field is nil AND whose id has an entry — a genuinely-local project
  /// never gains one. Returns whether anything was repaired so the caller can
  /// persist the healed catalog.
  static func repair(_ catalog: inout Catalog, sidecarURL: URL) -> Bool {
    let entries = read(at: sidecarURL)
    guard !entries.isEmpty else { return false }
    var repaired = false
    for index in catalog.projects.indices where catalog.projects[index].remoteHost == nil {
      if let host = entries[catalog.projects[index].id.raw.uuidString] {
        catalog.projects[index].remoteHost = host
        repaired = true
      }
    }
    return repaired
  }

  /// Write-through after every catalog save: adopt the catalog's current
  /// Server projects and prune entries whose project id left the catalog
  /// entirely (a deliberate project removal). An id still present but with a
  /// nil `remoteHost` KEEPS its entry — that state is exactly the stripping
  /// this sidecar exists to absorb, and must never propagate into it.
  static func sync(from catalog: Catalog, to url: URL) {
    guard var entries = load(at: url) else { return }
    let liveIDs = Set(catalog.projects.map { $0.id.raw.uuidString })
    entries = entries.filter { liveIDs.contains($0.key) }
    for project in catalog.projects {
      if let host = project.remoteHost {
        entries[project.id.raw.uuidString] = host
      }
    }
    if entries.isEmpty {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try? VersionedFile.write(entries, to: url, version: currentVersion)
  }
}
