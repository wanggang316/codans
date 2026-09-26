import CodansIPC
import ComposableArchitecture
import Foundation
import os

/// The last hierarchy and agent states streamed from one Mac, kept so a
/// cold start opens to something useful, marked stale, instead of a
/// spinner. The next snapshot replaces it; it is never merged.
nonisolated struct CachedWorkspace: Codable, Equatable, Sendable {
  /// Bumped when the layout changes; a file of another version is ignored,
  /// not migrated, since the next snapshot rebuilds it anyway.
  static let currentVersion = 1

  var version: Int = currentVersion
  /// When the data was last known to match the Mac.
  var savedAt: Date
  /// The Mac's `system.hello` protocol minor, so a cold start picks the
  /// live terminal or the text fallback before the first handshake.
  var protocolMinor: Int?
  var hierarchy: IPC.HierarchySummary?
  var agents: [IPC.AgentStateEntry]
}

/// Per-gateway storage of `CachedWorkspace`, in Application Support.
nonisolated struct WorkspaceCacheClient: Sendable {
  /// The cached workspace of a gateway; nil when there is none or it
  /// cannot be read.
  var load: @Sendable (_ gatewayID: UUID) async -> CachedWorkspace?
  var save: @Sendable (_ gatewayID: UUID, _ workspace: CachedWorkspace) async -> Void
  var remove: @Sendable (_ gatewayID: UUID) async -> Void
}

nonisolated extension WorkspaceCacheClient {
  private static let logger = Logger(subsystem: "com.gumpw.codans.mobile", category: "cache")

  /// Files named `<gateway-id>.json` under `directory`. Writes are atomic,
  /// so a crash mid-write leaves the previous file; any read or decode
  /// failure reads as "no cache", because the cache is only ever a head
  /// start.
  static func live(directory: URL) -> WorkspaceCacheClient {
    let file: @Sendable (UUID) -> URL = { directory.appendingPathComponent("\($0.uuidString).json") }
    return WorkspaceCacheClient(
      load: { id in
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let workspace = try? decoder.decode(CachedWorkspace.self, from: data),
          workspace.version == CachedWorkspace.currentVersion
        else {
          logger.notice("ignoring an unreadable workspace cache for \(id, privacy: .public)")
          return nil
        }
        return workspace
      },
      save: { id, workspace in
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let encoder = JSONEncoder()
          encoder.dateEncodingStrategy = .iso8601
          try encoder.encode(workspace).write(
            to: file(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
          logger.error("couldn't save the workspace cache: \(error.localizedDescription, privacy: .public)")
        }
      },
      remove: { id in
        try? FileManager.default.removeItem(at: file(id))
      }
    )
  }
}

nonisolated extension WorkspaceCacheClient: DependencyKey {
  static let liveValue: WorkspaceCacheClient = {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return .live(directory: base.appendingPathComponent("WorkspaceCache", isDirectory: true))
  }()

  static let testValue = WorkspaceCacheClient(
    load: unimplemented("WorkspaceCacheClient.load", placeholder: nil),
    save: unimplemented("WorkspaceCacheClient.save"),
    remove: unimplemented("WorkspaceCacheClient.remove")
  )

  /// Nothing cached, nothing kept.
  static let empty = WorkspaceCacheClient(load: { _ in nil }, save: { _, _ in }, remove: { _ in })
}

nonisolated extension DependencyValues {
  var workspaceCache: WorkspaceCacheClient {
    get { self[WorkspaceCacheClient.self] }
    set { self[WorkspaceCacheClient.self] = newValue }
  }
}
