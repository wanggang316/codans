import Foundation
import Testing

@testable import TouchCode

/// Pins the Coordinator's two-layer dedupe (queue dedupe + post-ready
/// send-cache) so SwiftUI's `updateNSView` storms can't re-trigger Shiki
/// tokenisation on every parent re-evaluation.
@MainActor
struct DiffWebViewCoordinatorTests {

  /// After the renderer is `ready`, two consecutive identical `.render`
  /// dispatches must invoke the evaluator only once.
  @Test
  func consecutiveIdenticalRenderDispatchesEvaluateOnce() {
    let coord = DiffWebViewCoordinator()
    let counter = CallCounter()
    coord.evaluator = { _ in counter.increment() }
    coord.markReadyForTesting()

    let script = #"window.__yitongReceiveMessage("payload-1")"#
    coord.dispatch(script: script, kind: .render)
    coord.dispatch(script: script, kind: .render)

    #expect(counter.value == 1)
  }

  /// Same dedupe applies to `.options`, independent of `.render`.
  @Test
  func consecutiveIdenticalOptionsDispatchesEvaluateOnce() {
    let coord = DiffWebViewCoordinator()
    let counter = CallCounter()
    coord.evaluator = { _ in counter.increment() }
    coord.markReadyForTesting()

    let script = #"window.__yitongReceiveMessage("opts-1")"#
    coord.dispatch(script: script, kind: .options)
    coord.dispatch(script: script, kind: .options)

    #expect(counter.value == 1)
  }

  /// A different script for the same kind must NOT be deduped.
  @Test
  func distinctRenderDispatchesEvaluateEachTime() {
    let coord = DiffWebViewCoordinator()
    let counter = CallCounter()
    coord.evaluator = { _ in counter.increment() }
    coord.markReadyForTesting()

    coord.dispatch(script: "render-a", kind: .render)
    coord.dispatch(script: "render-b", kind: .render)

    #expect(counter.value == 2)
  }

  /// Pre-ready: a fresh `.render` evicts a queued earlier `.render`. After
  /// `markReadyForTesting()` flushes, only the latest survives in arrival
  /// order alongside other queued kinds.
  @Test
  func preReadyRenderQueueDeDupesByKind() {
    let coord = DiffWebViewCoordinator()
    let captured = ScriptCapture()
    coord.evaluator = { captured.append($0) }

    coord.dispatch(script: "render-stale", kind: .render)
    coord.dispatch(script: "options-1", kind: .options)
    coord.dispatch(script: "render-fresh", kind: .render)

    coord.markReadyForTesting()

    #expect(captured.values == ["options-1", "render-fresh"])
  }

  /// `resetSendCache` clears both layers so a fresh WebView mount starts
  /// clean — otherwise an identical post-remount payload would be silently
  /// suppressed.
  @Test
  func resetSendCacheRestoresFreshDispatchPath() {
    let coord = DiffWebViewCoordinator()
    let counter = CallCounter()
    coord.evaluator = { _ in counter.increment() }
    coord.markReadyForTesting()

    coord.dispatch(script: "render-x", kind: .render)
    #expect(counter.value == 1)

    coord.dispatch(script: "render-x", kind: .render)
    #expect(counter.value == 1)  // suppressed by send-cache

    coord.resetSendCache()
    coord.markReadyForTesting()
    coord.dispatch(script: "render-x", kind: .render)
    #expect(counter.value == 2)  // cache cleared, dispatched again
  }

  // MARK: - Helpers

  private final class CallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
  }

  private final class ScriptCapture {
    private(set) var values: [String] = []
    func append(_ s: String) { values.append(s) }
  }
}
