import Darwin
import Dispatch
import Foundation

/// Collects one output pipe of a child process without trusting EOF to arrive.
///
/// EOF needs every write end of the pipe to close. Any process forked while
/// the pipe is open can inherit a write end: libghostty spawns each pane's
/// `zmx` with fork+exec and no close-on-exec sweep, and `zmx` then lives on
/// as a daemon. A reader that waits for EOF then blocks forever, although the
/// child it launched exited long ago — that froze a Project's worktree
/// reconcile (and held a `SubprocessGate` slot) for the rest of the session.
///
/// The collector reads through a dispatch source, so no thread blocks in
/// `read`. While the child runs it reads without a deadline. Once the caller
/// sees the child exit, `finish(grace:)` stops at EOF or at the grace
/// deadline, whichever comes first, and closes the read end.
nonisolated final class PipeCollector: @unchecked Sendable {
  /// How long to keep reading after the child exits. The child's own output
  /// is already in the pipe buffer by then; only a stray holder of the write
  /// end can keep the pipe open past it.
  static let defaultGrace: Duration = .seconds(2)

  private let queue = DispatchQueue(label: "codans.pipe-collector", qos: .utility)
  private let source: DispatchSourceRead
  private let done = DispatchGroup()
  private let maxBytes: Int
  private let onChunk: (@Sendable (Data) -> Void)?
  // Mutated only on `queue`; read after `done` signals.
  private var buffer = Data()
  private var overflow = false

  /// Starts reading `pipe` at once. Past `maxBytes` further bytes are
  /// discarded but reading continues, so the child never blocks on a full
  /// pipe. `onChunk` sees every chunk, including discarded ones, on a
  /// background queue.
  init(pipe: Pipe, maxBytes: Int = .max, onChunk: (@Sendable (Data) -> Void)? = nil) {
    let handle = pipe.fileHandleForReading
    let fd = handle.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    self.maxBytes = maxBytes
    self.onChunk = onChunk
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    done.enter()
    source.setEventHandler { [self] in readAvailable(fd: fd) }
    // The handle owns the descriptor; the source must stop using it first.
    source.setCancelHandler { [done] in
      try? handle.close()
      done.leave()
    }
    source.resume()
  }

  /// Waits for EOF, at most `grace` from now, then returns what was read.
  /// Call it once the child has exited (or failed to spawn).
  func finish(grace: Duration = defaultGrace) async -> (data: Data, overflow: Bool) {
    scheduleStop(after: grace)
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      done.notify(queue: queue) { cont.resume() }
    }
    return queue.sync { (buffer, overflow) }
  }

  /// Blocking form of `finish(grace:)` for synchronous callers.
  func finishBlocking(grace: Duration = defaultGrace) -> (data: Data, overflow: Bool) {
    scheduleStop(after: grace)
    done.wait()
    return queue.sync { (buffer, overflow) }
  }

  private func scheduleStop(after grace: Duration) {
    let (seconds, attoseconds) = grace.components
    let nanoseconds = max(0, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    // Cancelling an already-cancelled source is a no-op.
    queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [source] in source.cancel() }
  }

  private func readAvailable(fd: Int32) {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count > 0 {
        append(Data(chunk[0..<count]))
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN { return }
      // EOF or a read error: either way nothing more will arrive.
      source.cancel()
      return
    }
  }

  private func append(_ data: Data) {
    onChunk?(data)
    let room = maxBytes - buffer.count
    if data.count <= room {
      buffer.append(data)
    } else {
      if room > 0 { buffer.append(data.prefix(room)) }
      overflow = true
    }
  }
}

nonisolated extension Pipe {
  /// A pipe whose two descriptors close on exec, so a fork+exec elsewhere in
  /// the app (a pane spawn) does not inherit them. `Process` still hands the
  /// child its end: `posix_spawn` dup2s it onto 0/1/2, and dup2 clears the
  /// flag on the copy. Narrows the leak window; `PipeCollector` covers the
  /// remaining race between `pipe()` and `fcntl`.
  static func closeOnExec() -> Pipe {
    let pipe = Pipe()
    for fd in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
      _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
    }
    return pipe
  }
}
