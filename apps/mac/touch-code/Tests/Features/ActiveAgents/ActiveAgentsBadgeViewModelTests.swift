import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

/// Tests the four headline shapes produced by
/// `ActiveAgentsBadgeViewModel`. Pure value-type construction — we
/// feed `AgentEntry` arrays directly. `lastTransitionAt` is irrelevant
/// to the badge view model (the popover uses it for sort; the badge
/// only counts and groups), so every test uses a fixed timestamp.
@MainActor
struct ActiveAgentsBadgeViewModelTests {
  private let now = Date(timeIntervalSince1970: 1_000)

  /// Empty entries → no headline, no pulse. Caller hides the badge.
  @Test
  func emptyEntriesYieldNoHeadlineAndNoPulse() {
    let vm = ActiveAgentsBadgeViewModel(entries: [])
    #expect(vm.headline == nil)
    #expect(vm.pulse == false)
  }

  /// Single loading entry → "Claude Code is working", pulse on.
  @Test
  func singleLoadingClaudeCode() {
    let vm = ActiveAgentsBadgeViewModel(entries: [
      .init(kind: .claudeCode, sessionID: nil, state: .loading, lastTransitionAt: now)
    ])
    #expect(vm.headline == "Claude Code is working")
    #expect(vm.pulse == true)
  }

  /// Single idle entry → "Claude Code is idle", pulse off.
  @Test
  func singleIdleClaudeCode() {
    let vm = ActiveAgentsBadgeViewModel(entries: [
      .init(kind: .claudeCode, sessionID: nil, state: .idle, lastTransitionAt: now)
    ])
    #expect(vm.headline == "Claude Code is idle")
    #expect(vm.pulse == false)
  }

  /// Single waitingForInput → uses the full sentence verb
  /// "waiting for input" (the multi-state form collapses to "waiting").
  @Test
  func singleWaitingForInputUsesFullSentenceVerb() {
    let vm = ActiveAgentsBadgeViewModel(entries: [
      .init(kind: .codex, sessionID: nil, state: .waitingForInput, lastTransitionAt: now)
    ])
    #expect(vm.headline == "Codex is waiting for input")
    #expect(vm.pulse == true)
  }

  /// 3 entries all loading → "3 agents working", pulse on.
  @Test
  func multiSameStateAllLoading() {
    let entries: [AgentRegistry.AgentEntry] = (0..<3).map { _ in
      .init(kind: .claudeCode, sessionID: nil, state: .loading, lastTransitionAt: now)
    }
    let vm = ActiveAgentsBadgeViewModel(entries: entries)
    #expect(vm.headline == "3 agents working")
    #expect(vm.pulse == true)
  }

  /// Mixed (1 waiting + 2 loading + 1 finished) → "1 waiting · 2 working"
  /// — top two non-empty buckets in priority order `waitingForInput >
  /// loading > finished > idle`. `.finished` doesn't make the cut.
  @Test
  func mixedThreeBucketsKeepsTopTwo() {
    let entries: [AgentRegistry.AgentEntry] = [
      .init(kind: .claudeCode, sessionID: nil, state: .waitingForInput, lastTransitionAt: now),
      .init(kind: .codex, sessionID: nil, state: .loading, lastTransitionAt: now),
      .init(kind: .pi, sessionID: nil, state: .loading, lastTransitionAt: now),
      .init(kind: .claudeCode, sessionID: nil, state: .finished, lastTransitionAt: now),
    ]
    let vm = ActiveAgentsBadgeViewModel(entries: entries)
    #expect(vm.headline == "1 waiting · 2 working")
    #expect(vm.pulse == true)
  }

  /// Three states (1 waiting + 1 loading + 1 finished) → top two only
  /// → "1 waiting · 1 working". `.finished` is dropped per AC-B4.
  @Test
  func threeStatesShowTopTwoOnly() {
    let entries: [AgentRegistry.AgentEntry] = [
      .init(kind: .claudeCode, sessionID: nil, state: .waitingForInput, lastTransitionAt: now),
      .init(kind: .codex, sessionID: nil, state: .loading, lastTransitionAt: now),
      .init(kind: .pi, sessionID: nil, state: .finished, lastTransitionAt: now),
    ]
    let vm = ActiveAgentsBadgeViewModel(entries: entries)
    #expect(vm.headline == "1 waiting · 1 working")
    #expect(vm.pulse == true)
  }

  /// Two entries, same finished state → "2 agents finished", pulse off
  /// (neither loading nor waitingForInput).
  @Test
  func multiSameStateFinishedHasNoPulse() {
    let entries: [AgentRegistry.AgentEntry] = [
      .init(kind: .claudeCode, sessionID: nil, state: .finished, lastTransitionAt: now),
      .init(kind: .codex, sessionID: nil, state: .finished, lastTransitionAt: now),
    ]
    let vm = ActiveAgentsBadgeViewModel(entries: entries)
    #expect(vm.headline == "2 agents finished")
    #expect(vm.pulse == false)
  }
}
