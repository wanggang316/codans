import Testing

@testable import TouchCode

struct SocketPathsTests {
  @Test
  func channelPathsIncludeUID() {
    #expect(SocketPaths.productionSocketPath(uid: 1234) == "/tmp/touch-code-1234.sock")
    #expect(SocketPaths.developmentSocketPath(uid: 1234) == "/tmp/touch-code-dev-1234.sock")
  }

  @Test
  func defaultPathMatchesBuildChannel() {
    let path = SocketPaths.defaultSocketPath(uid: 1234)
    #if DEBUG
      #expect(path == "/tmp/touch-code-dev-1234.sock")
    #else
      #expect(path == "/tmp/touch-code-1234.sock")
    #endif
  }

  @Test
  func overrideWinsWhenNonEmpty() {
    #expect(SocketPaths.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }
}
