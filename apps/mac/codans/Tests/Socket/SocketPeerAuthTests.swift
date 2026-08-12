import Darwin
import Foundation
import Testing

@testable import Codans

@MainActor
struct SocketPeerAuthTests {
  @Test
  func selfConnectReturnsOwnUID() throws {
    let (serverFD, peerFD) = try Self.socketpair()
    defer {
      Darwin.close(serverFD)
      Darwin.close(peerFD)
    }
    let uid = SocketPeerAuth.peerUID(fd: serverFD)
    #expect(uid == getuid(), "socketpair peer must report our own UID")
  }

  @Test
  func authorizePassesOnMatchingUID() throws {
    let (serverFD, peerFD) = try Self.socketpair()
    defer {
      Darwin.close(serverFD)
      Darwin.close(peerFD)
    }
    let result = SocketPeerAuth.authorize(fd: serverFD)
    if case .failure(let err) = result {
      Issue.record("expected .success, got \(err)")
    }
  }

  @Test
  func authorizeRejectsMismatchedUID() throws {
    let (serverFD, peerFD) = try Self.socketpair()
    defer {
      Darwin.close(serverFD)
      Darwin.close(peerFD)
    }
    // Force a mismatch by passing a fabricated expected UID.
    let fabricated = getuid() &+ 12345
    let result = SocketPeerAuth.authorize(fd: serverFD, expectedUID: fabricated)
    switch result {
    case .success:
      Issue.record("expected .failure .uidMismatch")
    case .failure(let err):
      if case .uidMismatch(let expected, let got) = err {
        #expect(expected == fabricated)
        #expect(got == getuid())
      } else {
        Issue.record("expected .uidMismatch, got \(err)")
      }
    }
  }

  @Test
  func peerUIDReturnsNilOnInvalidFD() {
    let uid = SocketPeerAuth.peerUID(fd: -1)
    #expect(uid == nil)
  }

  @Test
  func peerPIDReportsSelfOnSocketpair() throws {
    let (serverFD, peerFD) = try Self.socketpair()
    defer {
      Darwin.close(serverFD)
      Darwin.close(peerFD)
    }
    #expect(SocketPeerAuth.peerPID(fd: serverFD) == getpid())
  }

  @Test
  func peerPIDReturnsNilOnInvalidFD() {
    #expect(SocketPeerAuth.peerPID(fd: -1) == nil)
  }

  // MARK: - Helpers

  static func socketpair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    let result = fds.withUnsafeMutableBufferPointer { buf in
      Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    if result != 0 {
      throw POSIXError(.EBADF)
    }
    return (fds[0], fds[1])
  }
}
