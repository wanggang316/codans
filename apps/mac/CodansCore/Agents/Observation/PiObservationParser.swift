import Foundation

nonisolated struct PiObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["pi>"]).joined(separator: "\n")
    return AgentObservationText.result(activity: Self.detectPi(screen), text: screen, promptPrefixes: ["pi>"])
  }

  private static func detectPi(_ content: String) -> AgentObservedActivity {
    content.contains("Working...") ? .working : .unknown
  }

}
