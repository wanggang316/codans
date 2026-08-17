import CodansCore
import Foundation
import Testing

@testable import Codans

struct SavedServerHostsTests {
  private static let host = RemoteHost(alias: "192.168.2.158", username: "gump")

  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-saved-hosts-\(UUID().uuidString)")
      .appendingPathComponent("saved-server-hosts.json")
  }

  @Test
  func missingFileReadsAsEmpty() {
    #expect(SavedServerHosts.read(at: tempURL()).isEmpty)
  }

  @Test
  func recordKeepsMostRecentFirstAndDeduplicates() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let other = RemoteHost(alias: "mini.local", username: "alice", port: 2299)
    SavedServerHosts.record(Self.host, at: url)
    SavedServerHosts.record(other, at: url)
    #expect(SavedServerHosts.read(at: url) == [other, Self.host])

    // Re-recording an existing host moves it to the front, no duplicate.
    SavedServerHosts.record(Self.host, at: url)
    #expect(SavedServerHosts.read(at: url) == [Self.host, other])

    // The same address as a different user or port is a distinct connection.
    let asRoot = RemoteHost(alias: Self.host.alias, username: "root")
    SavedServerHosts.record(asRoot, at: url)
    #expect(SavedServerHosts.read(at: url).count == 3)
  }

  @Test
  func recordCapsTheList() {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    for index in 0..<(SavedServerHosts.maxEntries + 3) {
      SavedServerHosts.record(RemoteHost(alias: "host-\(index)"), at: url)
    }
    let hosts = SavedServerHosts.read(at: url)
    #expect(hosts.count == SavedServerHosts.maxEntries)
    // Newest first, oldest three dropped.
    #expect(hosts.first?.alias == "host-\(SavedServerHosts.maxEntries + 2)")
    #expect(hosts.last?.alias == "host-3")
  }
}
