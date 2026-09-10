import Foundation
import Testing

@testable import Codans

@MainActor
struct WorktreeProcessDurationTests {
  @Test
  func missingRemoteStartTimeIsNotInvented() {
    #expect(WorktreeProcessDuration.label(startedAt: nil, now: .now) == "—")
  }

  @Test(arguments: [
    (0, "0s"), (59, "59s"), (60, "1m"), (3599, "59m"),
    (3600, "1h 0m"), (203_400, "56h 30m"), (360_000, "4d 4h"),
  ])
  func elapsedTimeRemainsCompact(seconds: Int, expected: String) {
    let start = Date(timeIntervalSince1970: 1_000)
    #expect(
      WorktreeProcessDuration.label(startedAt: start, now: start.addingTimeInterval(Double(seconds)))
        == expected
    )
  }

  @Test
  func clockCorrectionDoesNotProduceNegativeAge() {
    let now = Date(timeIntervalSince1970: 1_000)
    #expect(WorktreeProcessDuration.label(startedAt: now.addingTimeInterval(30), now: now) == "0s")
  }
}
