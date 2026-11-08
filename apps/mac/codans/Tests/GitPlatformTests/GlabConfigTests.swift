import CodansCore
import Foundation
import Testing

@testable import Codans

/// `GlabConfig` reads the hosts `glab` is logged in to from its `config.yml`, without
/// running `glab` (ADR 0004 item 2).
struct GlabConfigTests {
  /// The layout `glab` 1.128 writes: four-space indentation, a `gitlab.com` entry with no
  /// token, and a self-managed host with a port.
  @Test
  func fourSpaceIndentation() {
    let text = """
      git_protocol: ssh
      host: 192.168.2.158:8929
      hosts:
          gitlab.com:
              api_protocol: https
              api_host: gitlab.com
              token:
              custom_headers: []
          192.168.2.158:8929:
              use_keyring: "false"
              token: glpat-xxxx
              api_protocol: http
              user: codans-dev
      telemetry: true
      """
    #expect(GlabConfig.parseLoggedInHosts(text) == [.init(host: "192.168.2.158:8929", apiProtocol: "http")])
  }

  /// Older `glab` releases write two-space indentation and quote some keys.
  @Test
  func twoSpaceIndentationAndQuotedHost() {
    let text = """
      hosts:
        gitlab.com:
          token: 'glpat-aaaa'
          api_protocol: https
        "gitlab.corp.example.com":
          # comment
          token: "glpat-bbbb"
          headers:
            token: nested-value-is-ignored
      """
    #expect(
      GlabConfig.parseLoggedInHosts(text) == [
        .init(host: "gitlab.com", apiProtocol: "https"),
        .init(host: "gitlab.corp.example.com", apiProtocol: nil),
      ])
  }

  /// A token in the keyring leaves `token` empty.
  @Test
  func keyringHostIsLoggedIn() {
    let text = """
      hosts:
          gitlab.example.com:
              token:
              use_keyring: "true"
      """
    #expect(GlabConfig.parseLoggedInHosts(text) == [.init(host: "gitlab.example.com", apiProtocol: nil)])
  }

  @Test
  func noHostsKeyGivesNoHosts() {
    #expect(GlabConfig.parseLoggedInHosts("git_protocol: ssh\nhost: gitlab.com\n").isEmpty)
    #expect(GlabConfig.parseLoggedInHosts("").isEmpty)
  }

  // MARK: - file location

  @Test
  func glabConfigDirIsTheOnlyLocationWhenSet() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.writeConfig(host: "gitlab.home.example.com", in: root.appendingPathComponent("custom"))
    try Self.writeConfig(
      host: "gitlab.app-support.example.com",
      in: root.appendingPathComponent("Library/Application Support/glab-cli"))

    let env = ["GLAB_CONFIG_DIR": root.appendingPathComponent("custom").path]
    #expect(
      GlabConfig.loggedInHosts(environment: env, home: root.path).map(\.host) == ["gitlab.home.example.com"])
    #expect(GlabConfig.directories(environment: env, home: root.path).count == 1)
  }

  @Test
  func xdgConfigHomeComesBeforeTheMacOSLocation() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.writeConfig(host: "gitlab.xdg.example.com", in: root.appendingPathComponent("xdg/glab-cli"))
    try Self.writeConfig(
      host: "gitlab.app-support.example.com",
      in: root.appendingPathComponent("Library/Application Support/glab-cli"))

    let env = ["XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path]
    #expect(GlabConfig.loggedInHosts(environment: env, home: root.path).map(\.host) == ["gitlab.xdg.example.com"])
  }

  @Test
  func theMacOSLocationIsUsedWhenNoOtherFileExists() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.writeConfig(
      host: "gitlab.app-support.example.com",
      in: root.appendingPathComponent("Library/Application Support/glab-cli"))

    #expect(
      GlabConfig.loggedInHosts(environment: [:], home: root.path).map(\.host) == ["gitlab.app-support.example.com"])
  }

  @Test
  func aMissingFileGivesNoHosts() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(GlabConfig.loggedInHosts(environment: [:], home: root.path).isEmpty)
    let env = ["GLAB_CONFIG_DIR": root.appendingPathComponent("none").path]
    #expect(GlabConfig.loggedInHosts(environment: env, home: root.path).isEmpty)
  }

  /// `GitLabGitPlatform.authenticatedHosts` comes from the file and needs no `glab`.
  @Test
  func authenticatedHostsComeFromTheConfigWithoutGlab() async {
    let runner = RecordingCommandRunner(outcomes: [])
    let service = GitLabGitPlatform(
      runner: runner, resolver: .init(prober: { nil }),
      configHosts: { [.init(host: "192.168.2.158:8929", apiProtocol: "http")] })
    #expect(await service.authenticatedHosts() == ["192.168.2.158:8929"])
    #expect(await runner.calls.isEmpty)
    let repository = GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "g/app")
    #expect(service.repositoryWebURL(repository) == URL(string: "http://192.168.2.158:8929/g/app"))
  }

  // MARK: - helpers

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glab-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func writeConfig(host: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text = "hosts:\n    \(host):\n        token: glpat-test\n"
    try text.write(to: directory.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
  }
}
