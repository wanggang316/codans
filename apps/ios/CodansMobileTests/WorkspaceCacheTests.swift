import CodansIPC
import CodansRemote
import ComposableArchitecture
import Foundation
import Testing

@testable import CodansMobile

/// The per-Mac workspace cache on disk: round trip, one file per Mac, and
/// anything unreadable read as "no cache". Also the one retry idempotent
/// reads get.
struct WorkspaceCacheTests {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("WorkspaceCacheTests-\(UUID().uuidString)", isDirectory: true)

  private var cache: WorkspaceCacheClient { .live(directory: directory) }

  private static let workspace = CachedWorkspace(
    savedAt: Date(timeIntervalSince1970: 1_790_000_000), protocolMinor: 2, hierarchy: Fixtures.hierarchy,
    agents: [Fixtures.agent("A", state: "blocked", title: "Needs input")])

  @Test
  func savedWorkspaceReadsBackPerMac() async {
    defer { try? FileManager.default.removeItem(at: directory) }
    let other = UUID()

    #expect(await cache.load(Fixtures.deviceID) == nil)
    await cache.save(Fixtures.deviceID, Self.workspace)
    #expect(await cache.load(Fixtures.deviceID) == Self.workspace)
    #expect(await cache.load(other) == nil)

    await cache.remove(Fixtures.deviceID)
    #expect(await cache.load(Fixtures.deviceID) == nil)
  }

  @Test
  func unreadableOrOtherVersionFilesAreIgnored() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(Fixtures.deviceID.uuidString).json")

    try Data("{ not json".utf8).write(to: file)
    #expect(await cache.load(Fixtures.deviceID) == nil)

    var future = Self.workspace
    future.version = CachedWorkspace.currentVersion + 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(future).write(to: file)
    #expect(await cache.load(Fixtures.deviceID) == nil)

    // A good save replaces the bad file.
    await cache.save(Fixtures.deviceID, Self.workspace)
    #expect(await cache.load(Fixtures.deviceID) == Self.workspace)
  }

  @Test
  func idempotentReadsAreRetriedOnceAfterATimeout() async throws {
    let calls = LockIsolated(0)
    let value = try await RemoteClient.retryingOnce {
      let call = calls.withValue { value -> Int in
        value += 1
        return value
      }
      if call == 1 { throw RemoteRPCClient.ClientError.timeout }
      return "text"
    }
    #expect(value == "text")
    #expect(calls.value == 2)

    calls.setValue(0)
    await #expect(throws: RemoteRPCClient.ClientError.self) {
      try await RemoteClient.retryingOnce {
        calls.withValue { $0 += 1 }
        throw RemoteRPCClient.ClientError.connectionClosed
      }
    }
    #expect(calls.value == 1)
  }
}
