import Testing

@testable import Codans

struct SocketPathsTests {
  @Test
  func channelPathsIncludeUID() {
    #expect(SocketPaths.productionSocketPath(uid: 1234) == "/tmp/codans-1234.sock")
    #expect(SocketPaths.developmentSocketPath(uid: 1234) == "/tmp/codans-dev-1234.sock")
  }

  @Test
  func defaultPathMatchesBuildChannel() {
    let path = SocketPaths.defaultSocketPath(uid: 1234)
    #if DEBUG
      #expect(path == "/tmp/codans-dev-1234.sock")
    #else
      #expect(path == "/tmp/codans-1234.sock")
    #endif
  }

  @Test
  func overrideWinsWhenNonEmpty() {
    #expect(SocketPaths.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }
}
