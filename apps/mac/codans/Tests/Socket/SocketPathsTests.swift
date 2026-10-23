import CodansCore
import Testing

@testable import Codans

struct SocketPathsTests {
  @Test
  func channelPathsIncludeUID() {
    #expect(SocketPaths.productionSocketPath(uid: 1234) == "/tmp/codans-1234.sock")
    #expect(SocketPaths.developmentSocketPath(uid: 1234) == "/tmp/codans-dev-1234.sock")
  }

  @Test
  func defaultPathIsTheInstances() {
    #expect(SocketPaths.defaultSocketPath(uid: 1234) == "/tmp/\(AppInstance.slug)-1234.sock")
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
  func aWorktreeInstanceIgnoresTheSharedDevelopmentSocket() {
    // A worktree instance's app launched from a pane of the shared
    // development app inherits that app's socket; binding it would fail.
    let own = "/tmp/codans-dev-card-pane-1234.sock"
    #expect(SocketPaths.resolve(override: "/tmp/codans-dev-1234.sock", uid: 1234, ownDefault: own) == own)
    #expect(SocketPaths.resolve(override: "/tmp/codans-1234.sock", uid: 1234, ownDefault: own) == own)
    #expect(SocketPaths.resolve(override: own, uid: 1234, ownDefault: own) == own)
    #expect(SocketPaths.resolve(override: nil, uid: 1234, ownDefault: own) == own)
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
