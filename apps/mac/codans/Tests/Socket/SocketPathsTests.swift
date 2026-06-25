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

  @Test
  func ignoresInheritedForeignChannelDefaultSocket() {
    // A codans app launched from a host app's pane inherits CODANS_SOCKET_PATH
    // pointing at the host's (other-channel) default socket. The resolver must
    // discard that and use its own channel default — otherwise the child's
    // SocketServer binds the host's socket and fails with alreadyInUse, and it
    // advertises the wrong socket to its own panes.
    let inheritedHostSocket = SocketPaths.foreignChannelDefaultSocketPath(uid: 1234)
    let ownDefault = SocketPaths.defaultSocketPath(uid: 1234)
    #expect(SocketPaths.resolve(override: inheritedHostSocket, uid: 1234) == ownDefault)
    // Sanity: the inherited path really is the *other* channel, not our own.
    #expect(inheritedHostSocket != ownDefault)
  }

  @Test
  func honorsExplicitNonForeignOverride() {
    // An explicit override to a custom path (e.g. an isolated smoke socket) is
    // still honored — only the inherited foreign-channel default is discarded.
    #expect(
      SocketPaths.resolve(override: "/tmp/codans-smoke/sock", uid: 1234) == "/tmp/codans-smoke/sock"
    )
  }
}
