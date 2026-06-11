import Foundation
import Testing
import CodansCore

@testable import Codans

/// Parse-only performance baseline for `DiffParser`. Scoped to what is measurable before the
/// TCA shell lands: full reducer-dispatch + render measurement is the M8 test's job once
/// TCA is wired. This file is the groundwork — the sample loop + percentile + JSON
/// read/write stay stable when M8 extends the measured metrics.
///
/// Gated by `TC_RUN_PERFORMANCE_TESTS=1`. `TC_PERF_BASELINE=capture` overwrites the local
/// baseline; otherwise the test asserts against the baseline via the ceiling formula.
struct DiffParsePerformanceBaselineTests {
  static let performanceEnabled: Bool = {
    ProcessInfo.processInfo.environment["TC_RUN_PERFORMANCE_TESTS"] == "1"
  }()

  static let totalSamples = 50
  static let warmupSamples = 5
  static let driftMargin = 1.25
  static let parseMsDesignBudget = 80.0

  @Test(.enabled(if: DiffParsePerformanceBaselineTests.performanceEnabled))
  func measureDiffParseOfThousandLineFixture() throws {
    let fixture = try Self.loadFixture()
    precondition(!fixture.isEmpty, "fixture must be non-empty")

    // Warm-up pass — JIT / cache effects.
    for _ in 0..<Self.warmupSamples {
      _ = try DiffParser.parse(fixture, scope: .working)
    }

    // Measurement pass.
    var timings: [Double] = []
    timings.reserveCapacity(Self.totalSamples - Self.warmupSamples)
    for _ in Self.warmupSamples..<Self.totalSamples {
      let start = ContinuousClock.now
      let diff = try DiffParser.parse(fixture, scope: .working)
      let elapsed = ContinuousClock.now - start
      timings.append(Self.millis(elapsed))
      // Sanity — the fixture is expected to parse into one file with many hunks.
      precondition(!diff.files.isEmpty, "fixture parsed empty")
    }

    let stats = Self.stats(timings)
    Self.logResult(metric: "parse_ms", stats: stats)

    // If capture mode: write baseline.json. Else: assert against ceiling.
    let captureMode = ProcessInfo.processInfo.environment["TC_PERF_BASELINE"] == "capture"
    let baselineURL = try Self.baselineURL()
    if captureMode {
      try Self.writeBaseline(parseMs: stats, at: baselineURL)
      print(
        "[perf] baseline captured at \(baselineURL.path) — re-run without "
          + "TC_PERF_BASELINE=capture to assert against it")
    } else {
      let ceiling = try Self.ceiling(metric: "parse_ms", at: baselineURL, designBudget: Self.parseMsDesignBudget)
      let message: Comment =
        "parse_ms P95 \(stats.p95) exceeded ceiling \(ceiling) — baseline P95 × \(Self.driftMargin) vs design budget \(Self.parseMsDesignBudget) ms, whichever is greater"
      #expect(stats.p95 <= ceiling, message)
    }
  }

  // MARK: - Helpers

  struct Stats: Codable, Equatable {
    var p50: Double
    var p95: Double
    var max: Double
  }

  private static func stats(_ samples: [Double]) -> Stats {
    let sorted = samples.sorted()
    func pct(_ p: Double) -> Double {
      let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1))
      return sorted[idx]
    }
    return Stats(p50: pct(0.5), p95: pct(0.95), max: sorted.last ?? 0)
  }

  private static func millis(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1000.0 + Double(components.attoseconds) / 1e15
  }

  private static func logResult(metric: String, stats: Stats) {
    print(
      "[perf] \(metric): p50=\(String(format: "%.2f", stats.p50)) ms, "
        + "p95=\(String(format: "%.2f", stats.p95)) ms, " + "max=\(String(format: "%.2f", stats.max)) ms")
  }

  /// Fixture is bundled with the test target via `buildableFolders`. Loaded from the bundle.
  private static func loadFixture() throws -> Data {
    let bundle = Bundle(for: BundleAnchor.self)
    if let url = bundle.url(forResource: "diff-1000-lines", withExtension: "txt") {
      return try Data(contentsOf: url)
    }
    // Fallback: resolve by the source-tree layout when tests run out-of-bundle. This path
    // is reliable under the current Tuist setup; adjust if a future refactor moves the
    // fixture into a dedicated resource target.
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("fixtures", isDirectory: true)
      .appendingPathComponent("diff-1000-lines.txt", isDirectory: false)
    return try Data(contentsOf: sourceURL)
  }

  private static func baselineURL() throws -> URL {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("baseline.json", isDirectory: false)
    return sourceURL
  }

  private static func writeBaseline(parseMs: Stats, at url: URL) throws {
    struct Payload: Codable {
      var version: Int
      var machineKey: String
      var capturedAt: String
      var samples: [String: Stats]
    }
    let payload = Payload(
      version: 1,
      machineKey: Self.machineKey(),
      capturedAt: ISO8601DateFormatter().string(from: Date()),
      samples: ["parse_ms": parseMs]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: url, options: .atomic)
  }

  private static func ceiling(metric: String, at url: URL, designBudget: Double) throws -> Double {
    struct Payload: Codable {
      var samples: [String: Stats]
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      // No baseline → assert against the design ceiling only.
      return designBudget
    }
    let data = try Data(contentsOf: url)
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let baselineP95 = payload.samples[metric]?.p95 ?? designBudget
    return Swift.max(designBudget, baselineP95 * Self.driftMargin)
  }

  private static func machineKey() -> String {
    #if arch(arm64)
      return "arm64-apple-macos"
    #else
      return "x86_64-apple-macos"
    #endif
  }

  private final class BundleAnchor {}
}
