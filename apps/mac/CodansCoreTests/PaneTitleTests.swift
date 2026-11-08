import Foundation
import Testing

@testable import CodansCore

/// ADR 0009 pane title rules.
struct PaneTitleTests {
  private let home = "/Users/me"

  private func resolve(
    prompt: Bool, title: String?, directories: [String?] = ["/Users/me/dev/codans"]
  ) -> String? {
    PaneTitle.resolve(
      isAtShellPrompt: prompt, lastTitle: title, workingDirectories: directories,
      homeDirectory: home)
  }

  @Test
  func promptShowsTheDirectoryWhateverTitleTheShellSets() {
    #expect(resolve(prompt: true, title: "me@host:~/dev/codans") == "~/dev/codans")
  }

  @Test
  func runningProgramShowsItsTitle() {
    #expect(resolve(prompt: false, title: "✳ Claude Code") == "✳ Claude Code")
  }

  @Test
  func noTitleFallsBackToTheDirectory() {
    #expect(resolve(prompt: false, title: nil) == "~/dev/codans")
    #expect(resolve(prompt: false, title: "") == "~/dev/codans")
  }

  @Test
  func titleIsSanitized() {
    #expect(resolve(prompt: false, title: "\u{202E}vim\u{202C} a\u{200B}b") == "vim ab")
    #expect(resolve(prompt: false, title: "\u{200F}") == "~/dev/codans")
  }

  @Test
  func liveDirectoryWinsOverThePersistedOne() {
    #expect(
      resolve(prompt: true, title: nil, directories: [nil, "/Users/me/persisted"]) == "~/persisted")
    #expect(
      resolve(prompt: true, title: nil, directories: ["", "/Users/me/persisted"]) == "~/persisted")
    #expect(
      resolve(prompt: true, title: nil, directories: ["/tmp/live", "/Users/me/persisted"])
        == "/tmp/live")
  }

  @Test
  func promptWithoutDirectoryUsesTheTitle() {
    #expect(resolve(prompt: true, title: "zsh", directories: []) == "zsh")
    #expect(resolve(prompt: true, title: nil, directories: []) == nil)
  }

  @Test
  func homeAbbreviation() {
    #expect(PaneTitle.abbreviatingHome("/Users/me", homeDirectory: home) == "~")
    #expect(PaneTitle.abbreviatingHome("/Users/me/a", homeDirectory: home + "/") == "~/a")
    #expect(PaneTitle.abbreviatingHome("/Users/meow", homeDirectory: home) == "/Users/meow")
  }
}
