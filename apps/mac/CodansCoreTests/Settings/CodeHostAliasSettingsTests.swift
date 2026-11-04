import Foundation
import Testing

@testable import CodansCore

/// Code Host aliases in Settings › Code Hosts (ADR 0005).
struct CodeHostAliasSettingsTests {
  private static let gitlab = CodeHostAlias(remoteHost: "127.0.0.1", kind: .gitlab, apiHost: "192.168.2.158:8929")

  @Test
  func addEditAndDeleteAnAlias() throws {
    var general = GeneralSettings()
    try general.saveCodeHostAlias(Self.gitlab)
    #expect(general.codeHostAliases == [Self.gitlab])

    var edited = Self.gitlab
    edited.remoteHost = " SSH.Example.com "
    edited.kind = .github
    edited.apiHost = "GHE.example.com"
    try general.saveCodeHostAlias(edited)
    #expect(
      general.codeHostAliases == [
        CodeHostAlias(id: Self.gitlab.id, remoteHost: "ssh.example.com", kind: .github, apiHost: "ghe.example.com")
      ])

    general.removeCodeHostAlias(id: Self.gitlab.id)
    #expect(general.codeHostAliases.isEmpty)
  }

  @Test
  func aDuplicateRemoteHostIsRefused() throws {
    var general = GeneralSettings()
    try general.saveCodeHostAlias(Self.gitlab)
    let other = CodeHostAlias(remoteHost: "127.0.0.1", kind: .github, apiHost: "github.com")
    #expect(throws: CodeHostAliasError.duplicateRemoteHost("127.0.0.1")) {
      try general.saveCodeHostAlias(other)
    }
    #expect(general.codeHostAliases == [Self.gitlab])
  }

  @Test
  func anEditCannotTakeTheRemoteHostOfAnotherAlias() throws {
    var general = GeneralSettings()
    let second = CodeHostAlias(remoteHost: "ssh.example.com", kind: .gitlab, apiHost: "gitlab.example.com")
    try general.saveCodeHostAlias(Self.gitlab)
    try general.saveCodeHostAlias(second)
    var edited = second
    edited.remoteHost = "127.0.0.1"
    #expect(throws: CodeHostAliasError.duplicateRemoteHost("127.0.0.1")) {
      try general.saveCodeHostAlias(edited)
    }
    #expect(general.codeHostAliases == [Self.gitlab, second])
  }

  @Test(arguments: [
    "", "  ", "https://gitlab.example.com", "git@host", "host/path", "host:abc", "host:", "host:0", "host:65536",
    "a:1:2", "[]", "[::1", "[::1]x", "[::1]:", "[zz::1]", ".example.com", "example..com", "example.com.",
  ])
  func anInvalidHostIsRefused(host: String) {
    var general = GeneralSettings()
    #expect(throws: CodeHostAliasError.invalidRemoteHost) {
      try general.saveCodeHostAlias(CodeHostAlias(remoteHost: host, kind: .gitlab, apiHost: "gitlab.example.com"))
    }
    #expect(throws: CodeHostAliasError.invalidAPIHost) {
      try general.saveCodeHostAlias(CodeHostAlias(remoteHost: "gl", kind: .gitlab, apiHost: host))
    }
    #expect(general.codeHostAliases.isEmpty)
  }

  @Test(arguments: [
    "gitlab.example.com", "192.168.2.158:8929", "gl", "my_host-1.example.com:443", "[::1]", "[fe80::1]:8929",
    "localhost:65535",
  ])
  func aValidHostIsAccepted(host: String) {
    #expect(CodeHostAlias.isValidHost(host))
  }

  @Test
  func aliasesRoundTripAndAnEmptyListIsOmitted() throws {
    let empty = try #require(String(bytes: try JSONEncoder().encode(GeneralSettings()), encoding: .utf8))
    #expect(empty.contains("codeHostAliases") == false)

    let general = GeneralSettings(codeHostAliases: [Self.gitlab])
    let data = try JSONEncoder().encode(general)
    #expect(try JSONDecoder().decode(GeneralSettings.self, from: data) == general)
  }

  /// An entry a later version writes (unknown kind) is dropped; the others load.
  @Test
  func anAliasWithAnUnknownKindIsDropped() throws {
    let json = Data(
      #"""
      {"codeHostAliases":[
        {"id":"00000000-0000-0000-0000-000000000001","remoteHost":"a","kind":"gitea","apiHost":"a"},
        {"id":"00000000-0000-0000-0000-000000000002","remoteHost":"B","kind":"gitlab","apiHost":"b:8929"}
      ]}
      """#.utf8)
    let general = try JSONDecoder().decode(GeneralSettings.self, from: json)
    #expect(general.codeHostAliases.map(\.remoteHost) == ["b"])
  }

  /// ADR 0005 removes the Project Code Host choice. A file written before still loads,
  /// and the key is not written again.
  @Test
  func anOldProjectCodeHostChoiceLoadsAndIsNotWrittenAgain() throws {
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
