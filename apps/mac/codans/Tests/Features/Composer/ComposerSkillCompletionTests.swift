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
  func agentWithoutInvocationStyleNeverOpens() {
    let completion = completion(.none)
    completion.update(text: "/", caret: 1)
    #expect(!completion.isOpen)
  }

  @Test
  func noCaretUsesTheEndOfTheText() {
    let completion = completion()
    completion.update(text: "fix it /note", caret: nil)
    #expect(completion.query == .init(range: 7..<12, text: "note"))
    #expect(completion.matches.first?.name == "note")
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
}
