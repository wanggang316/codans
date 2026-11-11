import Darwin
import Foundation
import Testing

@testable import Codans

/// The Workspace source clone (`cloneStream`) against an HTTP server that
/// accepts the connection and never answers, so `git clone` hangs.
struct CloneStreamTimeoutTests {
  /// A listening socket on 127.0.0.1. The kernel completes the handshake,
  /// and nothing ever reads or writes.
  private final class SilentServer {
    let fd: Int32
    let port: UInt16

    init() throws {
      let fd = socket(AF_INET, SOCK_STREAM, 0)
      guard fd >= 0 else { throw POSIXError(.EIO) }
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      address.sin_port = 0
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard bound == 0, listen(fd, 8) == 0 else {
        close(fd)
        throw POSIXError(.EADDRINUSE)
      }
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
      }
      self.fd = fd
      port = UInt16(bigEndian: address.sin_port)
    }

    var url: String { "http://127.0.0.1:\(port)/repo.git" }

    deinit { close(fd) }
  }

  private func destination() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "codans-clone-\(UUID().uuidString)/repo", directoryHint: .isDirectory)
  }

  @Test
  func hungCloneTimesOut() async throws {
    let server = try SilentServer()
    let destination = destination()
    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
    let spawns = SpawnRecorder()
    var timeouts = GitWorktreeClient.StreamTimeouts()
    timeouts.clone = .seconds(3)
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) }, streamTimeouts: timeouts)

    await #expect {
      for try await _ in client.cloneStream(server.url, destination) {}
    } throws: { error in
      guard case .commandFailed(let command, let stderr) = error as? GitWorktreeError else { return false }
      return command == "git clone \(server.url)" && stderr == "did not finish in 3 seconds"
    }
    let pid = try #require(spawns.all.first)
    #expect(spawns.allLeadTheirGroup)
    #expect(await processGroupEnds(pid))
  }

  @Test
  func cancelledCloneLeavesNoProcess() async throws {
    let server = try SilentServer()
    let destination = destination()
    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
    let spawns = SpawnRecorder()
    let client = GitWorktreeClient.makeLive(onSpawn: { spawns.record($0) })

    let consumer = Task<Void, Error> {
      for try await _ in client.cloneStream(server.url, destination) {}
    }
    try await spawns.waitForSpawns(1)
    let pid = try #require(spawns.all.first)
    // Let git reach the server so a helper (`git-remote-http`) is running.
    try await Task.sleep(for: .milliseconds(500))
    consumer.cancel()

    #expect(await processGroupEnds(pid))
    _ = try? await consumer.value
  }
}
