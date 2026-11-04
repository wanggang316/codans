import CodansCore
import Testing

@testable import Codans

/// The status of each alias in Settings › Code Hosts (ADR 0005 item 4).
struct CodeHostAliasStatusTests {
  private let alias = CodeHostAlias(remoteHost: "127.0.0.1", kind: .gitlab, apiHost: "192.168.2.158:8929")

  @Test
  func checkingWhileTheCLIIsAsked() {
    #expect(CodeHostsSettingsView.aliasStatus(alias, loggedInHosts: nil) == .checking)
  }

  @Test
  func loggedInWhenTheCLIIsLoggedInToTheAPIHost() {
    #expect(
      CodeHostsSettingsView.aliasStatus(alias, loggedInHosts: ["gitlab.com", "192.168.2.158:8929"])
        == .loggedIn(cliName: "glab"))
  }

  /// The same message as the badge position shows for a missing login.
  @Test
  func notLoggedInShowsTheLoginMessage() {
    #expect(
      CodeHostsSettingsView.aliasStatus(alias, loggedInHosts: ["192.168.2.158"])
        == .notLoggedIn(message: CodeHostError.notAuthenticated(.gitlab, host: "192.168.2.158:8929").userFacingMessage))
  }
}
