import Foundation
import Testing

@testable import CodansCore

struct GitProjectSettingsLaunchAgentTests {
  @Test
  func launchAgentPickRoundTrips() throws {
    let git = GitProjectSettings(launchAgentProfileOnWorktreeCreate: UUID())
    let data = try JSONEncoder().encode(git)
    let decoded = try JSONDecoder().decode(GitProjectSettings.self, from: data)
    #expect(decoded == git)
    #expect(git.isEffectivelyEmpty == false)
  }

  @Test
  func noneIsOmittedAndCollapses() throws {
    let git = GitProjectSettings(launchAgentProfileOnWorktreeCreate: nil)
    let text = try #require(String(bytes: try JSONEncoder().encode(git), encoding: .utf8))
    #expect(text.contains("launchAgentProfileOnWorktreeCreate") == false)
    #expect(git.isEffectivelyEmpty)
  }
}
