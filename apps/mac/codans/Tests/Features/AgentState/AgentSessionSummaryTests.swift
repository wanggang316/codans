import Foundation
import Testing

@testable import Codans

struct AgentSessionSummaryTests {
  // MARK: - tailLines

  @Test
  func tailLinesDropsBlankLinesAndTrimsWhitespace() {
    let text = "  first  \n\n   \nsecond\n\nthird   \n\n"
    #expect(AgentSessionSummary.tailLines(text) == ["first", "second", "third"])
  }

  @Test
  func tailLinesCapsAtMaxLinesKeepingTheTail() {
    let text = (1...12).map { "line \($0)" }.joined(separator: "\n")
    let tail = AgentSessionSummary.tailLines(text, maxLines: 8)
    #expect(tail.count == 8)
    #expect(tail.first == "line 5")
    #expect(tail.last == "line 12")
  }

  @Test
  func tailLinesNilOrBlankTextYieldsEmpty() {
    #expect(AgentSessionSummary.tailLines(nil).isEmpty)
    #expect(AgentSessionSummary.tailLines("").isEmpty)
    #expect(AgentSessionSummary.tailLines("  \n \n\t\n").isEmpty)
  }

  // MARK: - durationText

  @Test
  func durationTextFormatsAcrossUnits() {
    let start = Date(timeIntervalSince1970: 0)
    func at(_ seconds: TimeInterval) -> String {
      AgentSessionSummary.durationText(from: start, to: start.addingTimeInterval(seconds))
    }
    #expect(at(0) == "0s")
    #expect(at(42) == "42s")
    #expect(at(60) == "1m")
    #expect(at(12 * 60 + 30) == "12m")
    #expect(at(3600) == "1h")
    #expect(at(3600 + 3 * 60) == "1h 3m")
    #expect(at(26 * 3600) == "1d")
    #expect(at(3 * 86_400) == "3d")
  }

  @Test
  func durationTextClampsNegativeElapsedToZero() {
    let start = Date(timeIntervalSince1970: 100)
    let earlier = Date(timeIntervalSince1970: 40)
    #expect(AgentSessionSummary.durationText(from: start, to: earlier) == "0s")
  }
}
