import Darwin
import Foundation
import Testing

@testable import Codans

/// Bring-up against a socket path that is already bound. A pane's zmx
/// daemon can inherit the app's listen fd and outlive the app: the path
/// then still accepts `connect(2)`, but nothing ever answers. Only a
/// server that answers the handshake may keep the path.
@MainActor
@Suite(.serialized)
struct SocketServerStaleSocketTests {
  @Test
  func startReclaimsAPathWhoseListenerNeverAnswers() throws {
    let path = Self.makeSocketPath()
    defer { unlink(path) }
    let orphan = try Self.listen(at: path)
    defer { Darwin.close(orphan) }
    let orphanInode = try Self.inode(at: path)

    let server = Self.makeServer(path: path)
    try server.start()
    defer { server.stop() }

    #expect(try Self.inode(at: path) != orphanInode)
  }

  @Test
  func startRefusesAPathWhoseServerAnswers() throws {
    let path = Self.makeSocketPath()
    defer { unlink(path) }
    let live = try Self.listen(at: path)
    defer { Darwin.close(live) }
    // Another app instance: reads the handshake and answers it.
    DispatchQueue.global().async {
      let client = Darwin.accept(live, nil, nil)
      guard client >= 0 else { return }
      var buffer = [UInt8](repeating: 0, count: 512)
      _ = Darwin.read(client, &buffer, buffer.count)
      let reply: [UInt8] = [0, 0, 0, 2, 0x7B, 0x7D]
      _ = Darwin.send(client, reply, reply.count, 0)
      Darwin.close(client)
    }

    let server = Self.makeServer(path: path)
    #expect(throws: SocketError.alreadyInUse(path: path)) {
      try server.start()
    }
  }

  @Test
  func listenDescriptorClosesOnExec() throws {
    let path = Self.makeSocketPath()
    defer { unlink(path) }
    let server = Self.makeServer(path: path)
    try server.start()
    defer { server.stop() }

    #expect(fcntl(server.listenFD, F_GETFD) & FD_CLOEXEC != 0)
  }

  @Test
  func acceptedDescriptorClosesOnExec() throws {
    let path = Self.makeSocketPath()
    defer { unlink(path) }
    let listener = try Self.listen(at: path)
    defer { Darwin.close(listener) }
    let client = try Self.connect(to: path)
    defer { Darwin.close(client) }

    let accepted = SocketServer.acceptCloseOnExec(listener)
    defer { Darwin.close(accepted) }

    #expect(accepted >= 0)
    #expect(fcntl(accepted, F_GETFD) & FD_CLOEXEC != 0)
  }

  // MARK: - Harness

  static func makeServer(path: String) -> SocketServer {
    let router = MethodRouter(systemHandlers: SystemHandlers(versions: .init(server: "0.0.0", appBundle: "0.0.0")))
    return SocketServer(path: path, router: router, probeTimeout: .milliseconds(200))
  }

  /// Short and under /tmp: `sun_path` holds 104 bytes.
  static func makeSocketPath() -> String {
    "/tmp/codans-test-\(UUID().uuidString.prefix(8)).sock"
  }

  static func listen(at path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var addr = address(path)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(bound == 0)
    try #require(Darwin.listen(fd, 8) == 0)
    return fd
  }

  static func connect(to path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var addr = address(path)
    let connected = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(connected == 0)
    return fd
  }

  static func address(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutablePointer(to: &addr.sun_path) {
      $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
        bytes.withUnsafeBufferPointer { _ = memcpy(dst, $0.baseAddress, bytes.count) }
      }
    }
    return addr
  }

  static func inode(at path: String) throws -> ino_t {
    var info = stat()
    try #require(lstat(path, &info) == 0)
    return info.st_ino
  }
}
