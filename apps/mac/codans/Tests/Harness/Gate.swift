import Foundation

/// One-shot gate so a test can hold a stubbed fetch open across other
/// actions, then release it. Models a `gh api graphql` still running when
/// the catalog mutates underneath it.
final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var opened = false

  func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      if opened {
        lock.unlock()
        c.resume()
        return
      }
      continuations.append(c)
      lock.unlock()
    }
  }

  func open() {
    lock.lock()
    opened = true
    let pending = continuations
    continuations = []
    lock.unlock()
    for continuation in pending { continuation.resume() }
  }
}
