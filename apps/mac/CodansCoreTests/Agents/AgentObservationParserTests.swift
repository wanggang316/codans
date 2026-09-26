import Foundation
import Testing

@testable import CodansCore

struct AgentObservationParserTests {
  private struct Fixture {
    let kind: AgentKind
    let working: String
    let blocked: String?
    let idle: String
  }

  private static let fixtures: [Fixture] = [
    .init(kind: .pi, working: "Working...", blocked: nil, idle: "pi> "),
    .init(
      kind: .claudeCode, working: "✢ Editing…",
      blocked: "Do you want to proceed?\n❯ 1. Yes\n  2. No", idle: "❯ "),
    .init(
      kind: .codex, working: "• Working (12s)",
      blocked: "Allow command?\n[y/n]", idle: "codex> "),
    .init(
      kind: .gemini, working: "Esc to cancel",
      blocked: "│ Do you want to proceed", idle: "gemini> "),
    .init(
      kind: .cursorAgent, working: "Ctrl+C to stop",
      blocked: "Run this command?\nRun (y) (enter)", idle: "cursor> "),
    .init(
      kind: .cline, working: "Esc to interrupt",
      blocked: "Let Cline use this tool?", idle: "cline> "),
    .init(
      kind: .opencode, working: "Esc to interrupt",
      blocked: "△ Permission required", idle: "opencode> "),
    .init(
      kind: .copilot, working: "Esc to cancel",
      blocked: "│ do you want to continue", idle: "copilot> "),
    .init(kind: .kimi, working: "thinking", blocked: "approve?", idle: "kimi> "),
    .init(
      kind: .droid, working: "⠋ Esc to stop",
      blocked: "EXECUTE\nenter to select\n> yes, allow", idle: "droid> "),
    .init(
      kind: .amp, working: "Esc to cancel",
      blocked: "Waiting for approval\nInvoke tool\nApprove\nAllow all for this session", idle: "amp> "),
    .init(kind: .grok, working: "Esc to interrupt", blocked: "[y/n]", idle: "grok> "),
    .init(
      kind: .omp, working: "⠋ Working… ⟦esc⟧",
      blocked: "Allow tool: bash\nReason: destructive\n❯ Approve\n  Deny", idle: "❯ fix the login bug"),
  ]

  @Test
  func everyParserRequiresPositiveEvidenceAndReportsInputSeparately() {
    #expect(Set(Self.fixtures.map(\.kind)) == Set(AgentKind.allCases))
    for fixture in Self.fixtures {
      let parser = AgentObservationParsers.parser(for: fixture.kind)
      let empty = parser.parse("")
      #expect(empty.state == .unknown)
      #expect(empty.inputAvailability == .unknown)
      #expect(empty.evidence.currentErrorBanner == nil)
      #expect(parser.parse("Ordinary response text").state == .unknown)
      #expect(parser.parse(fixture.working).state == .working)
      #expect(parser.parse(fixture.working).inputAvailability == .unavailable)
      if let blocked = fixture.blocked {
        #expect(parser.parse(blocked).state == .blocked)
        #expect(parser.parse(blocked).inputAvailability == .choice)
      }
      let idle = parser.parse(fixture.idle)
      #expect(idle.state == .idle)
      #expect(idle.inputAvailability == (fixture.kind == .omp ? .prompt(.occupied) : .prompt(.empty)))
    }
  }

  @Test
  func droidSelectionRowsAreLiveChromeRatherThanQuotedOutput() {
    let parsed = AgentObservationParsers.parser(for: .droid).parse(
      "> yes, allow\n> no, cancel\nenter to select")
    #expect(parsed.state == .blocked)
    #expect(parsed.inputAvailability == .choice)
  }

  @Test
  func finalErrorsOutrankHistoricalRetryAndWorkingCues() {
    for (kind, previous, banner, prompt) in [
      (AgentKind.codex, "Reconnecting... 5/5", "■ stream disconnected before completion: timeout", "›"),
      (.claudeCode, "Retrying in 3 seconds", "API Error: 503 unavailable", "❯"),
      (.codex, "• Working (12s)", "■ unexpected status 503: unavailable", "codex>"),
      (.claudeCode, "✢ Editing…", "⎿ API Error: 503 unavailable", "❯"),
    ] {
      let result = AgentObservationParsers.parser(for: kind).parse(previous + "\n" + banner + "\n" + prompt)
      guard case .error(let failure) = result.state else {
        Issue.record("Final error not selected: \(result)")
        continue
      }
      #expect(failure.reason == .transient)
      #expect(result.inputAvailability == .prompt(.empty))
      #expect(result.evidence.currentErrorBanner != nil)
      #expect(result.evidence.currentErrorBanner.map { result.evidence.visibleErrorBanners.contains($0) } == true)
    }
  }

  @Test
  func currentRetryAndPermissionCuesReplaceErrorsWithoutParallelCurrentFailure() {
    for (kind, banner, suffix, state, input) in [
      (
        AgentKind.codex, "■ unexpected status 503: unavailable", "Reconnecting... 1/5", AgentState.working,
        AgentInputAvailability.unavailable
      ),
      (.claudeCode, "API Error: 503", "Retrying in 3 seconds", .working, .unavailable),
      (.claudeCode, "API Error: 503", "Do you want to proceed? yes", .blocked, .choice),
    ] {
      let result = AgentObservationParsers.parser(for: kind).parse(banner + "\n" + suffix)
      #expect(result.state == state)
      #expect(result.inputAvailability == input)
      #expect(result.evidence.currentErrorBanner == nil)
      #expect(!result.evidence.visibleErrorBanners.isEmpty)
    }
  }

  @Test
  func promptAvailabilityNeverAssumesAnEmptyDraft() {
    let parser = AgentObservationParsers.parser(for: .claudeCode)
    for (suffix, input) in [
      ("", AgentInputAvailability.unknown), ("\n❯", .prompt(.empty)),
      ("\n❯ my unfinished draft", .prompt(.occupied)),
      ("\n❯ first line\ncontinued draft", .unknown),
    ] {
      let result = parser.parse("API Error: 503" + suffix)
      #expect(result.inputAvailability == input)
    }
    #expect(parser.parse("❯ my unfinished draft").state == .idle)
  }

  @Test
  func quotedAndOlderInteractionErrorsCannotBecomeCurrentFailures() {
    let parser = AgentObservationParsers.parser(for: .claudeCode)
    for text in ["Example: API Error: 503", "```\nAPI Error: 503", "> API Error: 503"] {
      #expect(parser.parse(text).state == .unknown)
      #expect(parser.parse(text).evidence.currentErrorBanner == nil)
    }
    let old = parser.parse("API Error: 503\n❯ next task\nresponse text\n❯")
    #expect(old.state == .idle)
    #expect(old.evidence.currentErrorBanner == nil)
    #expect(old.evidence.visibleErrorBanners == [.init(value: "API Error: 503")])
    #expect(parser.parse("```\nAPI Error: 503\n```\n❯").state == .idle)
  }

  @Test
  func errorsCarryPolicyMeaningAndCodableDetails() throws {
    let parser = AgentObservationParsers.parser(for: .claudeCode)
    for (message, reason, code, retryAfter) in [
      ("API Error: 503 unavailable", AgentFailure.Reason.transient, "503", nil as Int?),
      ("API Error: 429 rate limited Retry-After: 30", .rateLimited, "429", 30),
      ("API Error: 401 unauthorized", .authentication, "401", nil),
      ("API Error: 429 insufficient_quota", .quotaExceeded, "429", nil),
      ("API Error: 400 invalid model", .configuration, "400", nil),
      ("API Error: unexplained failure", .unknown, nil, nil),
    ] {
      let result = parser.parse(message)
      guard case .error(let failure) = result.state else {
        Issue.record("Missing failure for \(message)")
        continue
      }
      #expect(failure.reason == reason)
      #expect(failure.providerCode == code)
      #expect(failure.retryAfterSeconds == retryAfter)
      #expect(try JSONDecoder().decode(AgentFailure.self, from: JSONEncoder().encode(failure)) == failure)
    }
  }

  @Test
  func evidenceIsTerminalScopedAndControlledConstructionEnforcesErrorInvariant() {
    let banner = ErrorBannerSignature(value: "API Error: 503")
    let failure = AgentFailure(reason: .transient, message: banner.value)
    let error = TerminalParseResult.error(failure: failure, banner: banner)
    #expect(error.evidence.currentErrorBanner == banner)
    #expect(error.evidence.visibleErrorBanners == [banner])
    for value in [
      TerminalParseResult.unknown(visibleErrorBanners: [banner]), .idle(visibleErrorBanners: [banner]),
      .working(visibleErrorBanners: [banner]), .blocked(visibleErrorBanners: [banner]),
    ] {
      #expect(value.evidence.currentErrorBanner == nil)
      #expect(value.evidence.visibleErrorBanners == [banner])
    }
    let filler = Array(repeating: "Older transcript content", count: 30).joined(separator: "\n")
    let result = AgentObservationParsers.parser(for: .claudeCode).parse(
      "API Error: 401\n" + filler + "\nAPI Error: 503")
    #expect(result.evidence.visibleErrorBanners.count == 2)
    #expect(result.evidence.currentErrorBanner == banner)
  }

  @Test
  func trackerSeparatesCaptureSequenceFromStateOccurrenceAndExternalInput() {
    let instance = AgentInstanceID()
    var tracker = TerminalObservationTracker(instanceID: instance)
    let error = AgentObservationParsers.parser(for: .claudeCode).parse("API Error: 503\n❯")
    let time = Date(timeIntervalSince1970: 100)
    let first = tracker.accept(error, observedAt: time)
    let duplicate = tracker.accept(error, observedAt: time.addingTimeInterval(1))
    #expect(first.instanceID == instance)
    #expect(first.stateRevision == duplicate.stateRevision)
    #expect(duplicate.sequence == first.sequence + 1)
    #expect(duplicate.observedAt > first.observedAt)
    tracker.recordInput()
    #expect(tracker.lastObservation?.state == .unknown)
    #expect(tracker.lastObservation?.stateRevision != first.stateRevision)
    let dismissed = tracker.accept(error, observedAt: time.addingTimeInterval(2))
    #expect(dismissed.state == .idle)
    let duplicateDismissed = tracker.accept(error, observedAt: time.addingTimeInterval(3))
    #expect(dismissed.stateRevision == duplicateDismissed.stateRevision)
    _ = tracker.accept(
      .working(visibleErrorBanners: error.evidence.visibleErrorBanners), observedAt: time.addingTimeInterval(4))
    let repeated = tracker.accept(error, observedAt: time.addingTimeInterval(5))
    #expect(repeated.state == first.state)
    #expect(repeated.stateRevision > first.stateRevision)
  }

  @Test
  func suppressionWithoutPromptRemainsUnknownUntilNewEvidence() {
    let parser = AgentObservationParsers.parser(for: .claudeCode)
    let error = parser.parse("API Error: 503")
    var tracker = TerminalObservationTracker(instanceID: .init())
    _ = tracker.accept(error, observedAt: .distantPast)
    tracker.recordInput()
    #expect(tracker.accept(error, observedAt: .distantPast).state == .unknown)
    let draft = parser.parse("API Error: 503\n❯ typing draft")
    #expect(tracker.accept(draft, observedAt: .distantPast).state == .idle)
    #expect(tracker.accept(error, observedAt: .distantPast).state == .unknown)
    let newError = parser.parse("API Error: 504")
    #expect(tracker.accept(newError, observedAt: .distantPast).state == newError.state)
  }

  @Test
  func replacementCannotClaimOldErrorButDisappearanceEstablishesNewOccurrence() {
    let parser = AgentObservationParsers.parser(for: .claudeCode)
    let error = parser.parse("API Error: 503\n❯")
    var old = TerminalObservationTracker(instanceID: .init())
    let previous = old.accept(error, observedAt: .distantPast)
    var replacement = TerminalObservationTracker(instanceID: .init(), excludedErrorBanners: old.visibleErrorBanners)
    let residual = replacement.accept(error, observedAt: .distantFuture)
    #expect(residual.instanceID != previous.instanceID)
    #expect(residual.state == .idle)
    #expect(replacement.accept(error, observedAt: .distantFuture).stateRevision == residual.stateRevision)
    _ = replacement.accept(.unknown(), observedAt: .distantFuture)
    #expect(replacement.accept(error, observedAt: .distantFuture).state == error.state)
  }

  @Test
  func changedBannerCreatesOccurrenceEvenWhenFailureDetailsAreEqual() {
    var tracker = TerminalObservationTracker(instanceID: .init())
    let failure = AgentFailure(reason: .unknown, message: "Failure")
    let first = tracker.accept(.error(failure: failure, banner: .init(value: "one")), observedAt: .distantPast)
    let second = tracker.accept(.error(failure: failure, banner: .init(value: "two")), observedAt: .distantPast)
    #expect(first.state == second.state)
    #expect(first.stateRevision != second.stateRevision)
  }
}
