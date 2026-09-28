import Foundation
import Testing

@testable import CodansCore

struct TerminalLinkTests {
  private let home = "/Users/me"
  private let pwd = "/Users/me/repo"

  private func parse(_ raw: String, base: String? = "/Users/me/repo", existing: Set<String>? = []) -> TerminalLink? {
    TerminalLink.parse(
      raw, baseDirectory: base, homeDirectory: home,
      fileExists: existing.map { set in { set.contains($0) } }
    )
  }

  // MARK: - External URLs

  @Test(arguments: [
    "https://example.com/a?b=1#c",
    "http://localhost:3000",
    "mailto:someone@example.com",
    "vscode://file/Users/me/a.swift",
  ])
  func schemeURLsAreExternal(_ raw: String) {
    #expect(parse(raw) == .external(URL(string: raw)!))
  }

  @Test
  func fileURLBecomesFileLink() {
    #expect(parse("file:///Users/me/a%20b.txt") == .file(.init(path: "/Users/me/a b.txt")))
  }

  @Test
  func wordBeforeColonIsNotAScheme() {
    #expect(parse("App.swift:12") == .file(.init(path: "\(pwd)/App.swift", line: 12)))
  }

  // MARK: - Paths

  @Test
  func absolutePath() {
    #expect(parse("/tmp/x.log") == .file(.init(path: "/tmp/x.log")))
  }

  @Test
  func relativePathsResolveAgainstBase() {
    #expect(parse("src/App.swift") == .file(.init(path: "\(pwd)/src/App.swift")))
    #expect(parse("./src/App.swift") == .file(.init(path: "\(pwd)/src/App.swift")))
    #expect(parse("../other/x.md") == .file(.init(path: "/Users/me/other/x.md")))
  }

  @Test
  func homeExpansion() {
    #expect(parse("~/notes.md") == .file(.init(path: "/Users/me/notes.md")))
    #expect(parse("$HOME/notes.md") == .file(.init(path: "/Users/me/notes.md")))
    #expect(parse("~") == .file(.init(path: "/Users/me")))
    #expect(parse("~user/x") == .file(.init(path: "\(pwd)/~user/x")))
  }

  @Test
  func unknownHomeMakesTildePathsUnresolvable() {
    let link = TerminalLink.parse("~/a.md", baseDirectory: pwd, homeDirectory: nil)
    #expect(link == nil)
  }

  @Test
  func relativePathWithoutBaseIsUnresolvable() {
    #expect(parse("src/App.swift", base: nil) == nil)
    #expect(parse("~/a.md", base: nil) == .file(.init(path: "/Users/me/a.md")))
  }

  @Test
  func surroundingWhitespaceIsTrimmed() {
    #expect(parse("  /tmp/x.log   ") == .file(.init(path: "/tmp/x.log")))
    #expect(parse("   ") == nil)
  }

  // MARK: - Line / column suffix

  @Test
  func lineAndColumnSuffix() {
    #expect(parse("src/App.swift:42") == .file(.init(path: "\(pwd)/src/App.swift", line: 42)))
    #expect(parse("src/App.swift:42:7") == .file(.init(path: "\(pwd)/src/App.swift", line: 42, column: 7)))
    #expect(parse("/abs/App.swift:3:1") == .file(.init(path: "/abs/App.swift", line: 3, column: 1)))
  }

  @Test
  func invalidSuffixStaysInPath() {
    #expect(parse("src/App.swift:0") == .file(.init(path: "\(pwd)/src/App.swift:0")))
    #expect(parse("src/App.swift:abc") == .file(.init(path: "\(pwd)/src/App.swift:abc")))
    #expect(parse("src/a:1:2:3") == .file(.init(path: "\(pwd)/src/a:1", line: 2, column: 3)))
  }

  @Test
  func existingFileNamedWithColonWins() {
    let named = "\(pwd)/logs/run:12"
    #expect(parse("logs/run:12", existing: [named]) == .file(.init(path: named)))
    #expect(parse("logs/run:12", existing: []) == .file(.init(path: "\(pwd)/logs/run", line: 12)))
  }

  @Test
  func unknownFilesystemAlwaysStripsSuffix() {
    #expect(parse("src/App.swift:9", existing: nil) == .file(.init(path: "\(pwd)/src/App.swift", line: 9)))
  }
}
