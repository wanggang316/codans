import Foundation
import Testing

@testable import CodansCore

/// Git Platform aliases in Settings › Git Platforms (ADR 0005).
struct GitPlatformAliasSettingsTests {
  private static let gitlab = GitPlatformAlias(remoteHost: "127.0.0.1", kind: .gitlab, apiHost: "192.168.2.158:8929")

  @Test
  func addEditAndDeleteAnAlias() throws {
    var general = GeneralSettings()
    try general.saveGitPlatformAlias(Self.gitlab)
    #expect(general.gitPlatformAliases == [Self.gitlab])

    var edited = Self.gitlab
    edited.remoteHost = " SSH.Example.com "
    edited.kind = .github
    edited.apiHost = "GHE.example.com"
    try general.saveGitPlatformAlias(edited)
    #expect(
      general.gitPlatformAliases == [
        GitPlatformAlias(id: Self.gitlab.id, remoteHost: "ssh.example.com", kind: .github, apiHost: "ghe.example.com")
      ])

    general.removeGitPlatformAlias(id: Self.gitlab.id)
    #expect(general.gitPlatformAliases.isEmpty)
  }

  @Test
  func aDuplicateRemoteHostIsRefused() throws {
    var general = GeneralSettings()
    try general.saveGitPlatformAlias(Self.gitlab)
    let other = GitPlatformAlias(remoteHost: "127.0.0.1", kind: .github, apiHost: "github.com")
    #expect(throws: GitPlatformAliasError.duplicateRemoteHost("127.0.0.1")) {
      try general.saveGitPlatformAlias(other)
    }
    #expect(general.gitPlatformAliases == [Self.gitlab])
  }

  @Test
  func anEditCannotTakeTheRemoteHostOfAnotherAlias() throws {
    var general = GeneralSettings()
    let second = GitPlatformAlias(remoteHost: "ssh.example.com", kind: .gitlab, apiHost: "gitlab.example.com")
    try general.saveGitPlatformAlias(Self.gitlab)
    try general.saveGitPlatformAlias(second)
    var edited = second
    edited.remoteHost = "127.0.0.1"
    #expect(throws: GitPlatformAliasError.duplicateRemoteHost("127.0.0.1")) {
      try general.saveGitPlatformAlias(edited)
    }
    #expect(general.gitPlatformAliases == [Self.gitlab, second])
  }

  @Test(arguments: [
    "", "  ", "https://gitlab.example.com", "git@host", "host/path", "host:abc", "host:", "host:0", "host:65536",
    "a:1:2", "[]", "[::1", "[::1]x", "[::1]:", "[zz::1]", ".example.com", "example..com", "example.com.",
  ])
  func anInvalidHostIsRefused(host: String) {
    var general = GeneralSettings()
    #expect(throws: GitPlatformAliasError.invalidRemoteHost) {
      try general.saveGitPlatformAlias(GitPlatformAlias(remoteHost: host, kind: .gitlab, apiHost: "gitlab.example.com"))
    }
    #expect(throws: GitPlatformAliasError.invalidAPIHost) {
      try general.saveGitPlatformAlias(GitPlatformAlias(remoteHost: "gl", kind: .gitlab, apiHost: host))
    }
    #expect(general.gitPlatformAliases.isEmpty)
  }

  @Test(arguments: [
    "gitlab.example.com", "192.168.2.158:8929", "gl", "my_host-1.example.com:443", "[::1]", "[fe80::1]:8929",
    "localhost:65535",
  ])
  func aValidHostIsAccepted(host: String) {
    #expect(GitPlatformAlias.isValidHost(host))
  }

  @Test
  func aliasesRoundTripAndAnEmptyListIsOmitted() throws {
    let empty = try #require(String(bytes: try JSONEncoder().encode(GeneralSettings()), encoding: .utf8))
    #expect(empty.contains("gitPlatformAliases") == false)

    let general = GeneralSettings(gitPlatformAliases: [Self.gitlab])
    let data = try JSONEncoder().encode(general)
    #expect(try JSONDecoder().decode(GeneralSettings.self, from: data) == general)
  }

  /// An entry a later version writes (unknown kind) is dropped; the others load.
  @Test
  func anAliasWithAnUnknownKindIsDropped() throws {
    let json = Data(
      #"""
      {"gitPlatformAliases":[
        {"id":"00000000-0000-0000-0000-000000000001","remoteHost":"a","kind":"gitea","apiHost":"a"},
        {"id":"00000000-0000-0000-0000-000000000002","remoteHost":"B","kind":"gitlab","apiHost":"b:8929"}
      ]}
      """#.utf8)
    let general = try JSONDecoder().decode(GeneralSettings.self, from: json)
    #expect(general.gitPlatformAliases.map(\.remoteHost) == ["b"])
  }

  /// ADR 0005 removes the Project Git Platform choice. A file written before still loads,
  /// and the key is not written again.
  @Test
  func anOldProjectGitPlatformChoiceLoadsAndIsNotWrittenAgain() throws {
    let pid = "11111111-1111-1111-1111-111111111111"
    let json = Data(
      #"""
      {"version":3,"projects":{"\#(pid)":{"git":{"codeHost":"gitlab","worktreeBaseRef":"origin/main"}}}}
      """#.utf8)
    var settings = try JSONDecoder().decode(Settings.self, from: json)
    let projectID = ProjectID(raw: try #require(UUID(uuidString: pid)))
    #expect(settings.projects[projectID]?.git?.worktreeBaseRef == "origin/main")

    settings.garbageCollect()
    let text = try #require(String(bytes: try JSONEncoder().encode(settings), encoding: .utf8))
    #expect(text.contains("codeHost") == false)
    #expect(text.contains("worktreeBaseRef"))
  }

  @Test
  func aProjectWithOnlyTheOldChoiceIsDroppedOnSave() throws {
    let pid = "11111111-1111-1111-1111-111111111111"
    let json = Data(#"{"version":3,"projects":{"\#(pid)":{"git":{"codeHost":"github"}}}}"#.utf8)
    var settings = try JSONDecoder().decode(Settings.self, from: json)
    settings.garbageCollect()
    #expect(settings.projects.isEmpty)
  }
}
