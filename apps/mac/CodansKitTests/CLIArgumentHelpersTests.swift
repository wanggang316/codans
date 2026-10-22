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
      explicitTarget: nil,
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
      explicitTarget: nil,
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
      explicitTarget: "agent",
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
      explicitTarget: nil,
      stdin: "pwd",
      readsStdin: true,
      noEnter: false
    )
    #expect(input == CLIResolvedSendInput(target: "agent", text: "pwd\r"))
  }

  @Test
  func broadcastScopeRequiresExactlyOneSelection() throws {
    let scope = try CLIBroadcastScopeSelection.resolve(
      pane: nil,
      worktree: "current",
      label: nil
    )
    #expect(scope == .worktree("current"))
  }

  @Test
  func broadcastScopeRejectsNoSelection() {
    #expect(throws: CLIArgumentError.invalidScopeCount(expected: 1, actual: 0)) {
      try CLIBroadcastScopeSelection.resolve(pane: nil, worktree: nil, label: nil)
    }
  }

  @Test
  func broadcastScopeRejectsMultipleSelections() {
    #expect(throws: CLIArgumentError.invalidScopeCount(expected: 1, actual: 2)) {
      try CLIBroadcastScopeSelection.resolve(pane: "current", worktree: nil, label: "agent")
    }
  }

  @Test
  func broadcastScopeTakesAPane() throws {
    #expect(try CLIBroadcastScopeSelection.resolve(pane: "p2", worktree: nil, label: nil) == .pane("p2"))
  }

  @Test
  func targetDefaultsToTheCallingTab() throws {
    #expect(try CLITargetSelection.resolve(tab: nil, pane: nil, positional: nil) == .tab("current"))
  }

  @Test
  func positionalTargetIsATab() throws {
    #expect(try CLITargetSelection.resolve(tab: nil, pane: nil, positional: "t3") == .tab("t3"))
  }

  /// `--pane` keeps its own meaning (the pane's selected tab) so that
  /// `--pane current` is not the caller's own tab.
  @Test
  func paneTargetStaysAPaneSelection() throws {
    #expect(try CLITargetSelection.resolve(tab: nil, pane: "current", positional: nil) == .pane("current"))
    #expect(try CLITargetSelection.explicit(tab: nil, pane: "p1") == .pane("p1"))
    #expect(try CLITargetSelection.explicit(tab: "t1", pane: nil) == .tab("t1"))
    #expect(try CLITargetSelection.explicit(tab: nil, pane: nil) == nil)
  }

  @Test
  func targetRejectsTwoTargets() {
    #expect(throws: CLIArgumentError.self) {
      try CLITargetSelection.resolve(tab: "t1", pane: nil, positional: "t2")
    }
    #expect(throws: CLIArgumentError.self) {
      try CLITargetSelection.explicit(tab: "t1", pane: "p1")
    }
  }

  @Test
  func sendWithAnExplicitTargetKeepsEveryPositionalAsText() throws {
    let input = try CLISendInput.resolve(
      arguments: ["echo", "hi"], explicitTarget: "explicit", stdin: nil, readsStdin: false, noEnter: false)
    #expect(input.text == "echo hi\r")
  }

  @Test
  func everyMovedVerbNamesItsNewLocation() {
    let expected = [
      "pane new": "tab new", "pane show": "tab show", "pane send": "tab send",
      "pane send-key": "tab send-key", "pane capture": "tab capture", "pane read": "tab read",
      "pane info": "tab info", "pane label": "tab label", "pane reset": "tab reset", "tab switch": "tab focus",
    ]
    #expect(CLIMovedVerb.table == expected)
    for (old, new) in expected {
      let text = CLIMovedVerb.message(executable: "codans", from: old)
      #expect(text.message == "`codans \(old)` moved to `codans \(new)`")
      #expect(text.hint.contains("`codans \(new)`"))
    }
  }
}
