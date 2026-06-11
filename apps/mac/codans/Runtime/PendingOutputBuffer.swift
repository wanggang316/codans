import Foundation
import CodansCore

/// Per-pane output coalescer. Batches `append(bytes:)` calls and emits a
/// single `.paneOutput` event at most once per `flushInterval`, or when the
/// buffer reaches `maxBufferSize`. Callers MUST invoke `flush()` (or
/// `TerminalEngine.disposeOutputBuffer`) before releasing the buffer —
/// `deinit` only cancels the pending timer; any leftover bytes are dropped.
///
/// The previous safety-net drain was implemented as `isolated deinit`, but
/// in cascading-deinit chains (e.g. closing the last tab releases this
/// buffer alongside its `PaneSurface`) the Swift 6 `swift_task_deinit-
/// OnExecutorImpl` machinery double-frees TaskLocal scope storage and
/// trips libmalloc. A nonisolated deinit avoids the executor hop entirely
/// and the explicit `flush()` call already covers the well-formed path.
@MainActor
final class PendingOutputBuffer {
  let paneID: PaneID
  let flushInterval: Duration
  let maxBufferSize: Int

  private var buffer = Data()
  private var flushTask: Task<Void, Never>?
  private let emit: @MainActor @Sendable (PaneID, Data) -> Void

  init(
    paneID: PaneID,
    flushInterval: Duration = .milliseconds(16),
    maxBufferSize: Int = 16 * 1024,
    emit: @escaping @MainActor @Sendable (PaneID, Data) -> Void
  ) {
    self.paneID = paneID
    self.flushInterval = flushInterval
    self.maxBufferSize = maxBufferSize
    self.emit = emit
  }

  deinit {
    flushTask?.cancel()
  }

  func append(_ bytes: Data) {
    buffer.append(bytes)

    if buffer.count >= maxBufferSize {
      flush()
      return
    }

    if flushTask == nil {
      armFlushTimer()
    }
  }

  /// Public: cancel pending timer and drain any buffered bytes immediately.
  func flush() {
    flushTask?.cancel()
    flushTask = nil
    drain()
  }

  private func drain() {
    guard !buffer.isEmpty else { return }
    let payload = buffer
    buffer = Data()
    emit(paneID, payload)
  }

  private func armFlushTimer() {
    flushTask = Task { [weak self] in
      guard let interval = self?.flushInterval else { return }
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }
}
