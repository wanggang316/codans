import CodansCore
import Testing

@testable import Codans

/// The install probe is advisory and is wrong in the "missing" direction more
/// often than the other, so these pin both the filter and the two ways it
/// refuses to hide everything.
@MainActor
struct HeaderAgentSplitButtonTests {
  private static let claude = AgentProfile(kind: .claudeCode)
  private static let codex = AgentProfile(kind: .codex)
  private static let gemini = AgentProfile(kind: .gemini)

  @Test
  func hidesProfilesWhoseCLITheShellCouldNotResolve() {
    let offered = HeaderAgentSplitButton.offeredProfiles(
      enabled: [Self.claude, Self.codex, Self.gemini],
      isInstalled: { $0 != .codex }
    )
    #expect(offered.map(\.kind) == [.claudeCode, .gemini])
  }

  @Test
  func keepsEveryProfileWhenNoneLookInstalled() {
    // A probe that could not read the user's shell reports everything
    // missing. Hiding on that would leave the toolbar with nothing to launch
    // and no hint why.
    let enabled = [Self.claude, Self.codex]
    let offered = HeaderAgentSplitButton.offeredProfiles(
      enabled: enabled,
      isInstalled: { _ in false }
    )
    #expect(offered.map(\.kind) == enabled.map(\.kind))
  }

  @Test
  func anEmptyProfileListStaysEmpty() {
    // Distinct from the case above: nothing is configured, so there is
    // nothing to fail open to, and the button keeps its empty state.
    let offered = HeaderAgentSplitButton.offeredProfiles(
      enabled: [],
      isInstalled: { _ in false }
    )
    #expect(offered.isEmpty)
  }

  @Test
  func orderFollowsTheConfiguredList() {
    let offered = HeaderAgentSplitButton.offeredProfiles(
      enabled: [Self.gemini, Self.claude, Self.codex],
      isInstalled: { $0 != .claudeCode }
    )
    #expect(offered.map(\.kind) == [.gemini, .codex])
  }
}
