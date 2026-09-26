import Foundation

nonisolated struct PiObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectPi(screen))
  }

  private static func detectPi(_ content: String) -> AgentObservation.Activity {
    content.contains("Working...") ? .working : .idle
  }

}
