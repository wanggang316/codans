import Foundation
import Testing

@testable import CodansKit

struct SocketDiscoveryTests {
  @Test
  func channelPathsIncludeUID() {
    #expect(SocketDiscovery.productionSocketPath(uid: 1234) == "/tmp/codans-1234.sock")
    #expect(SocketDiscovery.developmentSocketPath(uid: 1234) == "/tmp/codans-dev-1234.sock")
  }

  @Test
  func defaultPathMatchesBuildChannel() {
    let path = SocketDiscovery.defaultSocketPath(uid: 1234)
    #if DEBUG
      #expect(path == "/tmp/codans-dev-1234.sock")
    #else
      #expect(path == "/tmp/codans-1234.sock")
    #endif
  }

  @Test
  func overrideWinsWhenNonEmpty() {
    #expect(SocketDiscovery.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }

  @Test
  func emptyOverrideFallsBackToDefault() {
    let fallback = SocketDiscovery.resolve(override: "")
    #if DEBUG
      #expect(fallback.hasPrefix("/tmp/codans-dev-"))
    #else
      #expect(fallback.hasPrefix("/tmp/codans-"))
    #endif
    #expect(fallback.hasSuffix(".sock"))
  }

  @Test
  func isReachableReturnsFalseForMissingPath() {
    let absent = "/tmp/codans-tests-\(UUID().uuidString).sock"
    #expect(SocketDiscovery.isReachable(path: absent) == false)
  }
}
