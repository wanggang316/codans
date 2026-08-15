import CodansCore
import Foundation
import Testing

@testable import Codans

struct RecentServerConnectionsTests {
  private static let host = RemoteHost(alias: "mini.local", username: "alice")

  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-recents-\(UUID().uuidString)")
      .appendingPathComponent("recent-connections.json")
  }

  @Test
  func missingFileReadsAsEmpty() {
    #expect(RecentServerConnections.read(at: tempURL()).isEmpty)
  }

  @Test
  func recordKeepsMostRecentFirstAndDeduplicates() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    RecentServerConnections.record(host: Self.host, path: "/srv/a", at: url)
    RecentServerConnections.record(host: Self.host, path: "/srv/b", at: url)
    // Same host, different path → two entries (a pick must fill every field).
    #expect(RecentServerConnections.read(at: url).map(\.path) == ["/srv/b", "/srv/a"])

    // Re-recording an existing pair moves it to the front, no duplicate.
    RecentServerConnections.record(host: Self.host, path: "/srv/a", at: url)
    #expect(RecentServerConnections.read(at: url).map(\.path) == ["/srv/a", "/srv/b"])
  }

  @Test
  func recordCapsTheList() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    for index in 0..<(RecentServerConnections.maxEntries + 3) {
      RecentServerConnections.record(host: Self.host, path: "/srv/\(index)", at: url)
    }
    let entries = RecentServerConnections.read(at: url)
    #expect(entries.count == RecentServerConnections.maxEntries)
    // Newest first, oldest three dropped.
    #expect(entries.first?.path == "/srv/\(RecentServerConnections.maxEntries + 2)")
    #expect(entries.last?.path == "/srv/3")
  }
}
