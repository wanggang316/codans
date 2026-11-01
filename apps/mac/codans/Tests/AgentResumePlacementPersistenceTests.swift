import CodansCore
import Foundation
import Testing

@testable import Codans

/// Serialized: both tests swap the shared static `store`.
@Suite(.serialized)
struct AgentResumePlacementPersistenceTests {
  private func freshSuite() -> UserDefaults {
    let name = "AgentResumePlacementPersistenceTests.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    suite.removePersistentDomain(forName: name)
    return suite
  }

  @Test
  func everyPlacementRoundTrips() {
    let all: [AgentResumePlacement] =
      [.newTab, .inPlace] + ScriptSplitDirection.allCases.map { .split($0) }
    AgentResumePlacementPersistence.withSuite(freshSuite()) {
      for placement in all {
        AgentResumePlacementPersistence.save(placement)
        #expect(AgentResumePlacementPersistence.load() == placement)
      }
    }
  }

  @Test
  func missingOrUnknownValueLoadsTheDefault() {
    let suite = freshSuite()
    AgentResumePlacementPersistence.withSuite(suite) {
      #expect(AgentResumePlacementPersistence.load() == .newTab)
      suite.set("split:sideways", forKey: AgentResumePlacementPersistence.key)
      #expect(AgentResumePlacementPersistence.load() == .newTab)
    }
  }
}
