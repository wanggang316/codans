import CodansCore
import Darwin
import Foundation
import Testing

@testable import CodansKit

struct SocketConnectionFailureTests {
  @Test
  func connectErrnosMapToCategories() {
    // The errno values below were confirmed against macOS: connecting to a
    // missing path yields ENOENT, to a regular file or directory ENOTSOCK,
    // and to a socket file whose listener is gone ECONNREFUSED.
    func kind(_ code: Int32) -> SocketFailureKind {
      SocketConnectionFailure.connect(errno: code, path: "/tmp/x.sock").kind
    }
    #expect(kind(ENOENT) == .socketMissing)
    #expect(kind(ENOTDIR) == .socketMissing)
    #expect(kind(ECONNREFUSED) == .appNotRunning)
    #expect(kind(EACCES) == .permissionDenied)
    #expect(kind(EPERM) == .permissionDenied)
    #expect(kind(ENOTSOCK) == .notASocket)
    #expect(kind(ENAMETOOLONG) == .pathTooLong)
    #expect(kind(EAGAIN) == .serverBusy)
    #expect(kind(ETIMEDOUT) == .timedOut)
    #expect(kind(EPIPE) == .connectionLost)
    #expect(kind(EDQUOT) == .unknown)
  }

  @Test
  func inFlightErrnosAreClassifiedAsLostConnections() {
    // Same errno, different phase: EPIPE at connect time is nonsense, but
    // on a live fd it means the app went away mid-request.
    let lost = SocketConnectionFailure.inFlight(errno: EPIPE, path: "/tmp/x.sock")
    #expect(lost.kind == .connectionLost)
    #expect(SocketConnectionFailure.inFlight(errno: ECONNRESET, path: "/x").kind == .connectionLost)
    #expect(SocketConnectionFailure.inFlight(errno: EDQUOT, path: "/x").kind == .unknown)
  }

  @Test
  func messagesNameThePathAndStayHintSeparate() {
    let missing = SocketConnectionFailure.connect(errno: ENOENT, path: "/tmp/codans-9.sock")
    #expect(missing.message.contains("/tmp/codans-9.sock"))
    #expect(missing.message.contains("not running"))
    #expect(missing.hint == "start it with `\(CLIInvocation.commandName) launch`")

    let denied = SocketConnectionFailure.connect(errno: EACCES, path: "/tmp/codans-9.sock")
    #expect(denied.message.contains("permission denied"))
    #expect(denied.hint?.isEmpty == false)
  }

  @Test
  func unknownErrnoIncludesTheRawNumber() {
    let failure = SocketConnectionFailure.connect(errno: EDQUOT, path: "/tmp/x.sock")
    #expect(failure.message.contains("errno=\(EDQUOT)"))
    #expect(failure.hint == nil)
  }

  @Test
  func launchOnlyHelpsForAppNotRunningCategories() {
    #expect(SocketFailureKind.socketMissing.isResolvedByLaunching)
    #expect(SocketFailureKind.appNotRunning.isResolvedByLaunching)
    #expect(SocketFailureKind.connectionLost.isResolvedByLaunching)
    #expect(SocketFailureKind.permissionDenied.isResolvedByLaunching == false)
    #expect(SocketFailureKind.notASocket.isResolvedByLaunching == false)
    #expect(SocketFailureKind.pathTooLong.isResolvedByLaunching == false)
  }

  @Test
  func rawValuesAreStableForScripts() {
    // `codans doctor --json` reports these strings; scripts branch on them.
    #expect(SocketFailureKind.socketMissing.rawValue == "socket-missing")
    #expect(SocketFailureKind.appNotRunning.rawValue == "app-not-running")
    #expect(SocketFailureKind.permissionDenied.rawValue == "permission-denied")
    #expect(SocketFailureKind.notASocket.rawValue == "not-a-socket")
    #expect(SocketFailureKind.pathTooLong.rawValue == "path-too-long")
    #expect(SocketFailureKind.serverBusy.rawValue == "server-busy")
    #expect(SocketFailureKind.timedOut.rawValue == "timed-out")
    #expect(SocketFailureKind.connectionLost.rawValue == "connection-lost")
    #expect(SocketFailureKind.socketCreateFailed.rawValue == "socket-create-failed")
    #expect(SocketFailureKind.unknown.rawValue == "unknown")
  }
}

/// End-to-end probes against real socket paths — these are what the CLI
/// actually hits, so they pin the classification to kernel behaviour
/// rather than to our reading of the man page.
struct SocketProbeTests {
  /// Under `/tmp`, not `NSTemporaryDirectory()` — the per-user temp dir is
  /// already ~50 bytes deep, and a socket path over the AF_UNIX `sun_path`
  /// limit (~104 bytes) classifies as `.pathTooLong` before any syscall.
  private func temporaryDirectory() throws -> URL {
    let suffix = UUID().uuidString.prefix(8)
    let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("cdp-\(suffix)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test
  func missingPathProbesAsSocketMissing() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let probe = SocketDiscovery.probe(path: dir.appendingPathComponent("absent.sock").path)
    #expect(probe.isReachable == false)
    #expect(probe.failure?.kind == .socketMissing)
  }

  @Test
  func regularFileProbesAsNotASocket() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("not-a-socket")
    try Data().write(to: file)
    let probe = SocketDiscovery.probe(path: file.path)
    #expect(probe.failure?.kind == .notASocket)
  }

  @Test
  func staleSocketFileProbesAsAppNotRunning() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("stale.sock").path

    // Bind + listen, then close the listener WITHOUT unlinking — exactly
    // what a crashed app leaves behind.
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(listener >= 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
        bytes.withUnsafeBufferPointer { src in _ = memcpy(dst, src.baseAddress, bytes.count) }
      }
    }
    let bound = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(listener, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(bound == 0)
    #expect(Darwin.listen(listener, 1) == 0)
    #expect(SocketDiscovery.probe(path: path).isReachable)  // live listener
    Darwin.close(listener)

    let probe = SocketDiscovery.probe(path: path)
    #expect(probe.isReachable == false)
    #expect(probe.failure?.kind == .appNotRunning)
  }

  @Test
  func overlongPathProbesAsPathTooLong() {
    let probe = SocketDiscovery.probe(path: "/tmp/" + String(repeating: "a", count: 200) + ".sock")
    #expect(probe.failure?.kind == .pathTooLong)
    // Classified before any syscall, so no errno to report.
    #expect(probe.failure?.errnoValue == nil)
  }
}
