import Foundation
import Testing

@testable import CodansKit

struct CLIArgumentHelpersTests {
  @Test
  func commandTextJoinsRemainingArguments() throws {
    let text = try CLICommandText.resolve(
      pieces: ["git", "status", "--short"],
      stdin: nil,
      readsStdin: false
    )
    #expect(text == "git status --short")
  }

  @Test
  func commandTextReadsStdinWhenRequested() throws {
    let text = try CLICommandText.resolve(
      pieces: [],
      stdin: "hello\n",
      readsStdin: true
    )
    #expect(text == "hello\n")
  }

  @Test
  func commandTextRejectsMissingInput() {
    #expect(throws: CLIArgumentError.missingText) {
      try CLICommandText.resolve(pieces: [], stdin: nil, readsStdin: false)
    }
  }

  @Test
  func commandTextRejectsTwoInputSources() {
    #expect(throws: CLIArgumentError.conflictingTextSources) {
      try CLICommandText.resolve(pieces: ["hello"], stdin: "world", readsStdin: true)
    }
  }

  @Test
  func commandTextAppendsEnterByDefault() {
    #expect(CLICommandText.appendEnterIfNeeded("pwd", noEnter: false) == "pwd\r")
    #expect(CLICommandText.appendEnterIfNeeded("pwd\r", noEnter: false) == "pwd\r")
    #expect(CLICommandText.appendEnterIfNeeded("pwd", noEnter: true) == "pwd")
  }

  @Test
  func sendInputOneArgumentTargetsCurrentPane() throws {
    let input = try CLISendInput.resolve(
      arguments: ["pwd"],
      explicitPane: nil,
      stdin: nil,
      readsStdin: false,
      noEnter: false
    )
    #expect(input == CLIResolvedSendInput(target: "current", text: "pwd\r"))
  }

  @Test
  func sendInputTwoArgumentsUseFirstAsTarget() throws {
    let input = try CLISendInput.resolve(
      arguments: ["agent", "git status --short"],
      explicitPane: nil,
      stdin: nil,
      readsStdin: false,
      noEnter: false
    )
    #expect(input == CLIResolvedSendInput(target: "agent", text: "git status --short\r"))
  }

  @Test
  func sendInputExplicitPaneKeepsAllArgumentsAsText() throws {
    let input = try CLISendInput.resolve(
      arguments: ["git", "status", "--short"],
      explicitPane: "agent",
      stdin: nil,
      readsStdin: false,
      noEnter: true
    )
    #expect(input == CLIResolvedSendInput(target: "agent", text: "git status --short"))
  }

  @Test
  func sendInputAllowsTargetWithStdin() throws {
    let input = try CLISendInput.resolve(
      arguments: ["agent"],
      explicitPane: nil,
      stdin: "pwd",
      readsStdin: true,
      noEnter: false
    )
    #expect(input == CLIResolvedSendInput(target: "agent", text: "pwd\r"))
  }

  @Test
  func broadcastScopeRequiresExactlyOneSelection() throws {
    let scope = try CLIBroadcastScopeSelection.resolve(
      tab: nil,
      worktree: "current",
      label: nil
    )
    #expect(scope == .worktree("current"))
  }

  @Test
  func broadcastScopeRejectsNoSelection() {
    #expect(throws: CLIArgumentError.invalidScopeCount(expected: 1, actual: 0)) {
      try CLIBroadcastScopeSelection.resolve(tab: nil, worktree: nil, label: nil)
    }
  }

  @Test
  func broadcastScopeRejectsMultipleSelections() {
    #expect(throws: CLIArgumentError.invalidScopeCount(expected: 1, actual: 2)) {
      try CLIBroadcastScopeSelection.resolve(tab: "current", worktree: nil, label: "agent")
    }
  }
}
