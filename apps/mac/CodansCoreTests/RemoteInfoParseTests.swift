import Foundation
import Testing

@testable import CodansCore

/// Pure-parser tests for `RemoteInfo.parse(_:)`. Covers every URL shape `git remote get-url`
/// is known to emit (SSH SCP-style, HTTPS, explicit `ssh://`) plus malformed inputs the
/// service layer must reject before dispatching GraphQL.
struct RemoteInfoParseTests {
  // MARK: - SSH / SCP-style

  @Test
  func parsesSCPStyleWithDotGitSuffix() throws {
    let info = try RemoteInfo.parse("git@github.com:wanggang316/codans.git")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  @Test
  func parsesSCPStyleWithoutDotGitSuffix() throws {
    let info = try RemoteInfo.parse("git@github.com:wanggang316/codans")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  // MARK: - HTTPS

  @Test
  func parsesHTTPSWithDotGitSuffix() throws {
    let info = try RemoteInfo.parse("https://github.com/wanggang316/codans.git")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  @Test
  func parsesHTTPSWithoutDotGitSuffix() throws {
    let info = try RemoteInfo.parse("https://github.com/wanggang316/codans")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  @Test
  func parsesHTTPSWithUserAuthority() throws {
    // Some environments stash a username into the https URL — `user@host/...` should be
    // tolerated and the user token stripped before host parsing.
    let info = try RemoteInfo.parse("https://gump@github.com/wanggang316/codans.git")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  // MARK: - ssh://

  @Test
  func parsesSSHSchemeStyle() throws {
    let info = try RemoteInfo.parse("ssh://git@github.com/wanggang316/codans.git")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  // MARK: - GitHub Enterprise host

  @Test
  func parsesEnterpriseHost() throws {
    // Non-github.com hosts are accepted — GHES installs vary. The caller decides whether
    // the host is one it supports.
    let info = try RemoteInfo.parse("git@github.example.corp:platform/monorepo.git")
    #expect(info.host == "github.example.corp")
    #expect(info.path == "platform/monorepo")
  }

  // MARK: - Nested group paths

  @Test
  func scpStyleKeepsNestedGroupPath() throws {
    let info = try RemoteInfo.parse("git@gitlab.com:group/sub/repo.git")
    #expect(info.host == "gitlab.com")
    #expect(info.path == "group/sub/repo")
  }

  @Test
  func httpsKeepsNestedGroupPath() throws {
    let info = try RemoteInfo.parse("https://gitlab.example.com/group/sub/deeper/repo.git")
    #expect(info.host == "gitlab.example.com")
    #expect(info.path == "group/sub/deeper/repo")
  }

  @Test
  func sshSchemeKeepsNestedGroupPath() throws {
    let info = try RemoteInfo.parse("ssh://git@gitlab.example.com/group/sub/repo")
    #expect(info.host == "gitlab.example.com")
    #expect(info.path == "group/sub/repo")
  }

  @Test
  func trailingSlashDoesNotAddAPathSegment() throws {
    let info = try RemoteInfo.parse("https://gitlab.com/group/sub/repo/")
    #expect(info.path == "group/sub/repo")
  }

  // MARK: - Malformed

  @Test
  func rejectsEmptyString() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("")
    }
  }

  @Test
  func rejectsWhitespaceOnlyString() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("   \n\t ")
    }
  }

  @Test
  func rejectsSCPStyleMissingOwner() {
    // "git@host:/repo" — colon-then-slash with no owner segment.
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("git@github.com:/codans.git")
    }
  }

  @Test
  func rejectsSCPStyleMissingRepo() {
    // "git@host:owner" — no slash, no repo segment.
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("git@github.com:wanggang316")
    }
  }

  @Test
  func rejectsHTTPSMissingRepo() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("https://github.com/wanggang316")
    }
  }

  @Test
  func rejectsUnknownScheme() {
    #expect(throws: RemoteInfo.ParseError.self) {
      _ = try RemoteInfo.parse("ftp://github.com/o/r.git")
    }
  }

  @Test
  func trimsLeadingAndTrailingWhitespace() throws {
    // `git remote get-url` emits a trailing newline — the parser must strip it.
    let info = try RemoteInfo.parse("  git@github.com:wanggang316/codans.git\n")
    #expect(info.host == "github.com")
    #expect(info.path == "wanggang316/codans")
  }

  // MARK: - Transport

  /// SSH remotes name an SSH host, which can be an alias from `~/.ssh/config`; the Git
  /// Platform resolver needs to know that (ADR 0004 item 2).
  @Test(arguments: [
    ("git@gl:codans-e2e/app.git", true),
    ("ssh://git@192.168.2.158:2222/codans-e2e/app.git", true),
    ("https://github.com/wanggang316/codans.git", false),
    ("http://192.168.2.158:8929/codans-e2e/app.git", false),
    ("git://example.com/group/repo.git", false),
  ])
  func marksSSHRemotes(url: String, isSSH: Bool) throws {
    #expect(try RemoteInfo.parse(url).isSSH == isSSH)
  }
}
