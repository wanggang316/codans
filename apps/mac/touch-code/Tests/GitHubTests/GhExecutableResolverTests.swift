import Foundation
import Testing

@testable import TouchCode

/// Covers the four behaviours of `GhExecutableResolver` documented in exec-plan 0012 M0:
///   - missing binary returns nil
///   - present binary is cached across calls
///   - concurrent callers share a single resolution (single-flight)
///   - explicit invalidation forces re-probe
///
/// Tests inject a counting prober closure rather than hitting the filesystem. The
/// live-FS path is exercised indirectly by the M2 integration tests against real `gh`.
struct GhExecutableResolverTests {
  /// Counts how many times the prober was invoked so tests can assert caching / single-flight.
  actor ProbeCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private func makeProber(
    counter: ProbeCounter,
    returning url: URL?,
    delay: Duration = .zero
  ) -> GhExecutableResolver.Prober {
    { @Sendable in
      await counter.increment()
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      return url
    }
  }

  @Test
  func missingBinaryReturnsNil() async {
    let counter = ProbeCounter()
    let resolver = GhExecutableResolver(prober: makeProber(counter: counter, returning: nil))
    let result = await resolver.resolve()
    #expect(result == nil)
    await #expect(counter.count == 1)
  }

  @Test
  func resolvedValueCachesAcrossCalls() async {
    let counter = ProbeCounter()
    let stubURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    let resolver = GhExecutableResolver(prober: makeProber(counter: counter, returning: stubURL))

    let first = await resolver.resolve()
    let second = await resolver.resolve()
    let third = await resolver.resolve()

    #expect(first == stubURL)
    #expect(second == stubURL)
    #expect(third == stubURL)
    await #expect(counter.count == 1, "prober should run once and subsequent calls hit the cache")
  }

  @Test
  func concurrentCallersShareSingleResolution() async {
    let counter = ProbeCounter()
    let stubURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    // A non-zero delay widens the in-flight window so concurrent callers reliably catch the
    // `.resolving` state rather than racing through to `.resolved`.
    let resolver = GhExecutableResolver(
      prober: makeProber(counter: counter, returning: stubURL, delay: .milliseconds(50))
    )

    let results = await withTaskGroup(of: URL?.self, returning: [URL?].self) { group in
      for _ in 0..<16 {
        group.addTask { await resolver.resolve() }
      }
      var collected: [URL?] = []
      for await url in group {
        collected.append(url)
      }
      return collected
    }

    #expect(results.count == 16)
    #expect(results.allSatisfy { $0 == stubURL })
    await #expect(counter.count == 1, "single-flight: 16 concurrent callers share one probe")
  }

  @Test
  func invalidationForcesReprobe() async {
    let counter = ProbeCounter()
    let stubURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
    let resolver = GhExecutableResolver(prober: makeProber(counter: counter, returning: stubURL))

    _ = await resolver.resolve()
    _ = await resolver.resolve()
    await #expect(counter.count == 1)

    await resolver.invalidate()

    _ = await resolver.resolve()
    _ = await resolver.resolve()
    await #expect(counter.count == 2, "invalidate() clears the cache so the next resolve re-probes")
  }
}
