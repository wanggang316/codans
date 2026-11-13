import CodansCore
import Foundation
import Testing

@testable import Codans

@MainActor
struct ComposerSkillCompletionTests {
  private static func skill(_ name: String, _ summary: String? = nil) -> AgentSkillEntry {
    AgentSkillEntry(
      name: name, summary: summary, source: .user, url: URL(fileURLWithPath: "/tmp/skills/\(name)"))
  }

  private static let skills = [
    skill("code-review", "Review a change"),
    skill("tdd", "Test-driven development"),
    skill("review-pr", "Review a pull request"),
    skill("note", "Write a note"),
  ]

  private func completion(
    _ location: SkillLocation = .claudeCode, skills: [AgentSkillEntry] = skills
  ) -> ComposerSkillCompletion {
    let completion = ComposerSkillCompletion()
    completion.location = location
    completion.skills = skills
    return completion
  }

  // MARK: - Trigger

  @Test
  func prefixAtPromptStartOpensTheList() {
    let completion = completion()
    completion.update(text: "/", caret: 1)
    #expect(completion.isOpen)
    #expect(completion.query == .init(range: 0..<1, text: ""))
    #expect(completion.matches == Self.skills)
  }

  @Test
  func prefixAfterWhitespaceOpensTheListWhenCallsRunAnywhere() {
    let completion = completion()
    completion.update(text: "please /td", caret: 10)
    #expect(completion.query == .init(range: 7..<10, text: "td"))
    #expect(completion.matches.map(\.name) == ["tdd"])
  }

  @Test
  func prefixInsideAWordDoesNotOpen() {
    let completion = completion()
    completion.update(text: "src/main", caret: 8)
    #expect(!completion.isOpen)
    completion.update(text: "/tdd now", caret: 8)
    #expect(!completion.isOpen)
  }

  @Test
  func leadingPositionOpensOnlyAtPromptStart() {
    let leading = SkillLocation(
      userDirectories: [], invocationStyle: .slash, invocationPosition: .leading)
    let completion = completion(leading)
    completion.update(text: "please /td", caret: 10)
    #expect(!completion.isOpen)
    completion.update(text: "  /td", caret: 5)
    #expect(completion.isOpen)
  }

  @Test
  func eachStyleOpensOnItsPrefixAndInsertsItsToken() {
    let cases: [(SkillLocation, String, String)] = [
      (.codex, "$no", "$note "),
      (.pi, "/no", "/skill:note "),
    ]
    for (location, typed, inserted) in cases {
      let completion = completion(location)
      completion.update(text: typed, caret: typed.utf16.count)
      #expect(completion.matches.first?.name == "note", "\(typed)")
      #expect(completion.handle(.accept, text: typed) == .insert(text: inserted, caret: inserted.utf16.count))
    }
  }

  @Test
  func typedSkillMarkerIsNotPartOfTheQuery() {
    let completion = completion(.pi)
    completion.update(text: "/skill:no", caret: 9)
    #expect(completion.matches.first?.name == "note")
    #expect(completion.handle(.accept, text: "/skill:no") == .insert(text: "/skill:note ", caret: 12))
  }

  @Test
  func otherPrefixesDoNotOpen() {
    let completion = completion(.codex)
    completion.update(text: "/no", caret: 3)
    #expect(!completion.isOpen)
  }

  @Test
  func agentWithoutInvocationStyleNeverOpens() {
    let completion = completion(.none)
    completion.update(text: "/", caret: 1)
    #expect(!completion.isOpen)
  }

  @Test
  func selectedRangeOpensNothing() {
    let completion = completion()
    completion.update(text: "/note", caret: 5)
    #expect(completion.isOpen)
    completion.update(text: "/note", caret: nil)
    #expect(!completion.isOpen)
    #expect(completion.query == nil)
  }

  @Test
  func skillsThatLoadAfterThePrefixOpenTheList() {
    let completion = completion(skills: [])
    completion.update(text: "/td", caret: 3)
    #expect(!completion.isOpen)
    completion.skills = Self.skills
    #expect(completion.isOpen)
    #expect(completion.matches.map(\.name) == ["tdd"])
  }

  @Test
  func pickingACallTheTextNoLongerHoldsChangesNothing() {
    let completion = completion()
    completion.update(text: "fix /td", caret: 7)
    #expect(completion.isOpen)
    // The text changed under the list without an update (the call is gone).
    #expect(completion.select(Self.skills[1], text: "fix td") == .handled)
    #expect(!completion.isOpen)
  }

  @Test
  func caretInTheMiddleUsesTextBeforeIt() {
    let completion = completion()
    completion.update(text: "/tdd and more", caret: 3)
    #expect(completion.query == .init(range: 0..<3, text: "td"))
  }

  // MARK: - Filter

  @Test
  func namePrefixMatchesComeFirst() {
    let names = ComposerSkillCompletion.filter(Self.skills, query: "review").map(\.name)
    #expect(names == ["review-pr", "code-review"])
  }

  @Test
  func fuzzyMatchesNameAndDescription() {
    #expect(ComposerSkillCompletion.filter(Self.skills, query: "cdrv").map(\.name) == ["code-review"])
    #expect(ComposerSkillCompletion.filter(Self.skills, query: "pull").map(\.name) == ["review-pr"])
    #expect(ComposerSkillCompletion.filter(Self.skills, query: "TDD").map(\.name) == ["tdd"])
  }

  @Test
  func emptyResultClosesTheList() {
    let completion = completion()
    completion.update(text: "/zzz", caret: 4)
    #expect(!completion.isOpen)
    #expect(completion.matches.isEmpty)
  }

  // MARK: - Keys

  @Test
  func arrowsMoveAndWrap() {
    let completion = completion()
    completion.update(text: "/", caret: 1)
    #expect(completion.handle(.down, text: "/") == .handled)
    #expect(completion.highlighted?.name == "tdd")
    #expect(completion.handle(.up, text: "/") == .handled)
    #expect(completion.handle(.up, text: "/") == .handled)
    #expect(completion.highlighted?.name == "note")
  }

  @Test
  func acceptReplacesTheTypedCallWithTheToken() {
    let completion = completion()
    let text = "first /rev then"
    completion.update(text: text, caret: 10)
    let outcome = completion.handle(.accept, text: text)
    #expect(outcome == .insert(text: "first /review-pr then", caret: 17))
    #expect(!completion.isOpen)
  }

  @Test
  func selectingARowInsertsIt() {
    let completion = completion()
    completion.update(text: "/", caret: 1)
    #expect(completion.select(Self.skills[1], text: "/") == .insert(text: "/tdd ", caret: 5))
  }

  @Test
  func pluginSkillInsertsItsPluginColonSkillCall() {
    let plugin = AgentSkillEntry(
      name: "docs:pdf", summary: "Read PDFs", source: .plugin,
      url: URL(fileURLWithPath: "/tmp/plugins/docs/skills/pdf"))
    let completion = completion(skills: Self.skills + [plugin])
    let text = "open /pd"
    completion.update(text: text, caret: 8)
    #expect(completion.matches.first == plugin)
    #expect(completion.handle(.accept, text: text) == .insert(text: "open /docs:pdf ", caret: 15))
  }

  @Test
  func escapeClosesOnlyTheListUntilTheCallEnds() {
    let completion = completion()
    completion.update(text: "/t", caret: 2)
    #expect(completion.handle(.dismiss, text: "/t") == .handled)
    #expect(!completion.isOpen)
    completion.update(text: "/td", caret: 3)
    #expect(!completion.isOpen)
    completion.update(text: "/td /", caret: 5)
    #expect(completion.isOpen)
  }

  @Test
  func closedListIgnoresKeysSoTheOwnerSendsAndCloses() {
    let completion = completion()
    completion.update(text: "fix it", caret: 6)
    for key: ComposerSkillCompletion.Key in [.accept, .dismiss, .up, .down] {
      #expect(completion.handle(key, text: "fix it") == .ignored)
    }
  }

  @Test
  func changingTheAgentClosesTheList() {
    let completion = completion()
    completion.update(text: "/", caret: 1)
    completion.location = .none
    #expect(!completion.isOpen)
  }

  // MARK: - Skills button

  @Test
  func prefixGoesAtTheCaretAndOpensTheList() {
    let result = ComposerSkillCompletion.insertingPrefix(
      "/", into: "fix  now", selection: 4..<4, position: .anywhere)
    #expect(result?.text == "fix / now")
    #expect(result?.caret == 5)
    let completion = completion()
    completion.update(text: result!.text, caret: result!.caret)
    #expect(completion.isOpen)
    #expect(completion.matches == Self.skills)
    #expect(
      completion.handle(.accept, text: result!.text)
        == .insert(text: "fix /code-review now", caret: 17))
  }

  @Test
  func prefixAfterAWordGetsASpaceFirst() {
    let result = ComposerSkillCompletion.insertingPrefix(
      "/", into: "fix", selection: nil, position: .anywhere)
    #expect(result?.text == "fix /")
    #expect(result?.caret == 5)
  }

  @Test
  func prefixReplacesTheSelection() {
    let result = ComposerSkillCompletion.insertingPrefix(
      "/", into: "run tests", selection: 4..<9, position: .anywhere)
    #expect(result?.text == "run /")
    #expect(result?.caret == 5)
  }

  @Test
  func leadingPrefixGoesAtThePromptStart() {
    let result = ComposerSkillCompletion.insertingPrefix(
      "/", into: "fix it", selection: 6..<6, position: .leading)
    #expect(result?.text == "/fix it")
    #expect(result?.caret == 1)
    let empty = ComposerSkillCompletion.insertingPrefix(
      "/", into: "", selection: nil, position: .leading)
    #expect(empty?.text == "/")
    #expect(empty?.caret == 1)
  }

  // MARK: - Model invocation

  private static let skillsWithManualOnly =
    skills + [
      AgentSkillEntry(
        name: "deploy", summary: "Deploy", source: .user,
        url: URL(fileURLWithPath: "/tmp/skills/deploy"), disablesModelInvocation: true)
    ]

  @Test
  func skillWithoutModelInvocationIsListedAtThePromptStart() {
    let completion = completion(skills: Self.skillsWithManualOnly)
    completion.update(text: "  /deploy", caret: 9)
    #expect(completion.matches.map(\.name) == ["deploy"])
    completion.update(text: "/", caret: 1)
    #expect(completion.matches.contains { $0.name == "deploy" })
  }

  @Test(arguments: [SkillLocation.claudeCode, .codex, .pi])
  func manualSkillCanBeSelectedAtAnyPromptPosition(location: SkillLocation) throws {
    let token = try #require(location.invocationStyle.token(for: "deploy"))
    for prefix in ["", "Please run ", "First review.\nThen run "] {
      let completion = completion(location, skills: Self.skillsWithManualOnly)
      let text = prefix + token + " on staging"
      let caret = (prefix + token).utf16.count
      completion.update(text: text, caret: caret)
      #expect(completion.matches.map(\.name) == ["deploy"])
      #expect(completion.isOpen)
      #expect(completion.handle(.accept, text: text) == .insert(text: text, caret: caret + 1))
    }
  }

  // MARK: - Pointer

  @Test
  func highlightMovesToAMatchAndIgnoresOtherSkills() {
    let completion = completion()
    completion.update(text: "/", caret: 1)
    completion.highlight(Self.skills[2])
    #expect(completion.highlighted == Self.skills[2])
    // Up and Down continue from the row the pointer picked.
    _ = completion.handle(.down, text: "/")
    #expect(completion.highlighted == Self.skills[3])
    completion.highlight(Self.skill("other"))
    #expect(completion.highlighted == Self.skills[3])
  }

  @Test
  func pointerMovingOntoARowHighlightsIt() {
    let completion = completion()
    completion.update(text: "/", caret: 1)
    var pointer = ComposerSkillCompletionPointer(at: CGPoint(x: 10, y: 10))
    pointer.hovered(Self.skills[1], at: CGPoint(x: 10, y: 34), in: completion)
    #expect(completion.highlighted == Self.skills[1])
  }

  /// A row can come under a pointer that does not move: the list opens
  /// under it, scrolls, or refilters. That row does not take the highlight
  /// from the keyboard.
  @Test
  func listRefiltersUnderAStationaryPointerHighlightUnchanged() {
    let completion = completion()
    let resting = CGPoint(x: 10, y: 34)
    completion.update(text: "/", caret: 1)
    var pointer = ComposerSkillCompletionPointer(at: resting)
    pointer.hovered(Self.skills[1], at: resting, in: completion)
    #expect(completion.highlighted == Self.skills[0])

    _ = completion.handle(.down, text: "/")
    _ = completion.handle(.down, text: "/")
    #expect(completion.highlighted == Self.skills[2])
    // Refilter: another row is now under the same point.
    completion.update(text: "/re", caret: 3)
    let highlighted = completion.highlighted
    pointer.hovered(Self.skills[0], at: resting, in: completion)
    #expect(completion.highlighted == highlighted)
  }
}
