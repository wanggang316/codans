import Foundation
import Testing

@testable import CodansCore

/// The Project "Code Host" choice (ADR 0004 item 10). `nil` is Auto.
struct GitProjectSettingsCodeHostTests {
  @Test(arguments: CodeHostKind.allCases)
  func aChosenCodeHostRoundTrips(kind: CodeHostKind) throws {
    let git = GitProjectSettings(codeHost: kind)
    let data = try JSONEncoder().encode(git)
    let text = try #require(String(bytes: data, encoding: .utf8))
    #expect(text.contains("\"codeHost\":\"\(kind.rawValue)\""))
    #expect(try JSONDecoder().decode(GitProjectSettings.self, from: data) == git)
    #expect(git.isEffectivelyEmpty == false)
  }

  @Test
  func autoIsOmittedAndCollapses() throws {
    let git = GitProjectSettings(codeHost: nil)
    let text = try #require(String(bytes: try JSONEncoder().encode(git), encoding: .utf8))
    #expect(text.contains("codeHost") == false)
    #expect(git.isEffectivelyEmpty)
  }

  /// A value that a later version writes reads as Auto, so the rest of the subtree
  /// still loads.
  @Test
  func anUnknownCodeHostReadsAsAuto() throws {
    let json = Data(#"{"codeHost":"gitea","worktreeBaseRef":"origin/main"}"#.utf8)
    let git = try JSONDecoder().decode(GitProjectSettings.self, from: json)
    #expect(git.codeHost == nil)
    #expect(git.worktreeBaseRef == "origin/main")
  }
}
