import Darwin
import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// Bind-time behavior of the real `SocketServer`: which fds a spawned pane
/// can inherit, and how `start()` treats a socket path that already exists.
@MainActor
struct SocketServerStartTests {
  @Test
  func listenSocketIsCloseOnExec() throws {
    let path = try Self.makeSocketPath()
    defer { Self.removeSocketDir(path) }
    let server = Self.makeServer(path: path)
    try server.start()
    defer { server.stop() }

    let listeners = Self.socketFDs(boundTo: path, listening: true)
    #expect(listeners.count == 1)
    for fd in listeners {
      #expect(Self.isCloseOnExec(fd), "pane processes must not inherit the listen socket")
    }
  }

  @Test
  func acceptedConnectionIsCloseOnExec() async throws {
    let path = try Self.makeSocketPath()
    defer { Self.removeSocketDir(path) }
    let server = Self.makeServer(path: path)
    try server.start()
    defer { server.stop() }

    let client = try Self.connect(to: path)
    defer { Darwin.close(client) }

    var accepted: [Int32] = []
    for _ in 0..<200 {
      accepted = Self.socketFDs(boundTo: path, listening: false)
      if !accepted.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(accepted.count == 1)
    for fd in accepted {
      #expect(Self.isCloseOnExec(fd), "pane processes must not inherit an accepted connection")
    }
  }

  /// A pane process that inherited the listen socket of an earlier app
  /// instance keeps it alive after that app dies. `connect(2)` to the path
  /// then succeeds, but nothing ever accepts. `start()` must take the path
  /// over instead of reporting `alreadyInUse`.
  @Test
  func startTakesOverPathHeldByListenerThatNeverAccepts() async throws {
    let path = try Self.makeSocketPath()
    defer { Self.removeSocketDir(path) }
    let orphan = try Self.bindAndListen(path: path)
    defer { Darwin.close(orphan) }

    let server = Self.makeServer(path: path)
    try server.start()
    defer { server.stop() }

    // Off the main actor: the server hands accepted connections to it.
    let answered = try await Task.detached { try Self.answersRequest(at: path) }.value
    #expect(answered, "a client on the path must reach the new server")
  }

  /// The live peer is another app instance in production. In-process, a
  /// second `SocketServer` cannot answer while `start()` holds the main
  /// actor, so a background thread plays that instance.
  @Test
  func startRefusesPathServedByLiveServer() throws {
    let path = try Self.makeSocketPath()
    defer { Self.removeSocketDir(path) }
    let live = try Self.bindAndListen(path: path)
    defer { Darwin.close(live) }
    Thread.detachNewThread {
      let peer = Darwin.accept(live, nil, nil)
      guard peer >= 0 else { return }
      var reply: UInt8 = 0
      _ = Darwin.write(peer, &reply, 1)
      // Hold the connection open past the probe so the reply is read
      // before any hang-up.
      Thread.sleep(forTimeInterval: 1)
      Darwin.close(peer)
    }

    let second = Self.makeServer(path: path)
    #expect(throws: SocketError.alreadyInUse(path: path)) {
      try second.start()
    }
  }

  /// A live instance whose main thread is busy accepts nothing in time. The
  /// listener's creator is still alive and has our process name, so the
  /// path is not stale.
  @Test
  func startRefusesPathWhoseListenerCreatorIsStillRunning() throws {
    let path = try Self.makeSocketPath()
    defer { Self.removeSocketDir(path) }
    let creator = try Self.forkSilentListener(path: path)
    defer {
      kill(creator, SIGKILL)
      var status: Int32 = 0
      waitpid(creator, &status, 0)
    }

    let server = Self.makeServer(path: path)
    #expect(throws: SocketError.alreadyInUse(path: path)) {
      try server.start()
    }
  }

  // MARK: - Harness

  static func makeServer(path: String) -> SocketServer {
    let systemHandlers = SystemHandlers(versions: .init(server: "0.3.0", appBundle: "0.3.0+test"))
    return SocketServer(path: path, router: MethodRouter(systemHandlers: systemHandlers))
  }

  /// Under `/tmp`, not `NSTemporaryDirectory()`: `sun_path` holds 104 bytes.
  static func makeSocketPath() throws -> String {
    let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("codans-sst-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("s.sock").path
  }

  static func removeSocketDir(_ path: String) {
    unlink(path)
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
  }

  nonisolated static func socketAddress(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      let bytes = Array(path.utf8)
      raw.copyBytes(from: bytes.prefix(raw.count - 1))
    }
    return addr
  }

  nonisolated static func withSockaddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var addr = socketAddress(path)
    return withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  static func bindAndListen(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    try #require(withSockaddr(path) { Darwin.bind(fd, $0, $1) } == 0)
    try #require(Darwin.listen(fd, 8) == 0)
    return fd
  }

  /// Fork a child of this test process (same process name) that listens
  /// on `path` and never accepts. Returns after the socket is listening.
  /// The child runs only async-signal-safe calls.
  static func forkSilentListener(path: String) throws -> pid_t {
    var addr = socketAddress(path)
    var ready: [Int32] = [0, 0]
    try #require(pipe(&ready) == 0)
    // Swift marks `fork()` unavailable; the child here only makes syscalls.
    typealias Fork = @convention(c) () -> pid_t
    let forkSymbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork"))
    let pid = unsafeBitCast(forkSymbol, to: Fork.self)()
    if pid == 0 {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, Darwin.listen(fd, 8) == 0 else { _exit(1) }
      var byte: UInt8 = 1
      _ = Darwin.write(ready[1], &byte, 1)
      while true { pause() }
    }
    Darwin.close(ready[1])
    defer { Darwin.close(ready[0]) }
    try #require(pid > 0)
    var byte: UInt8 = 0
    try #require(Darwin.read(ready[0], &byte, 1) == 1, "listener child failed to listen")
    return pid
  }

  nonisolated static func connect(to path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    try #require(withSockaddr(path) { Darwin.connect(fd, $0, $1) } == 0)
    return fd
  }

  /// Send one framed request and wait for any reply. The server answers a
  /// pre-hello frame with a handshake error, which is enough to prove that
  /// something accepts and serves on the path.
  nonisolated static func answersRequest(at path: String) throws -> Bool {
    let fd = try connect(to: path)
    defer { Darwin.close(fd) }
    let body = try JSONEncoder().encode(IPC.Request(id: "probe", method: .systemPing))
    let frame = try Framing.encode(body)
    let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, frame.count, 0) }
    try #require(sent == frame.count)
    var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&pollFD, 1, 2_000) == 1 else { return false }
    var byte: UInt8 = 0
    return Darwin.read(fd, &byte, 1) == 1
  }

  /// Server-side sockets in this process whose local address is `path`.
  /// Client fds have no local address, so they never match.
  static func socketFDs(boundTo path: String, listening: Bool) -> [Int32] {
    (0..<Int32(getdtablesize())).filter { fd in
      var st = stat()
      guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return false }
      var addr = sockaddr_un()
      var len = socklen_t(MemoryLayout<sockaddr_un>.size)
      let named = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
      }
      guard named == 0, addr.sun_family == sa_family_t(AF_UNIX) else { return false }
      let local = withUnsafeBytes(of: addr.sun_path) { raw in
        String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8)
      }
      guard local == path else { return false }
      // Darwin has no SO_ACCEPTCONN; a listener is the one without a peer.
      var peer = sockaddr_un()
      var peerLen = socklen_t(MemoryLayout<sockaddr_un>.size)
      let connected = withUnsafeMutablePointer(to: &peer) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &peerLen) }
      }
      return (connected != 0) == listening
    }
  }

  static func isCloseOnExec(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFD)
    return flags >= 0 && (flags & FD_CLOEXEC) != 0
  }
}
