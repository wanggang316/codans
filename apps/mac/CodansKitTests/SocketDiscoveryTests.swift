import Foundation
import Testing

@testable import CodansKit

struct SocketDiscoveryTests {
  @Test
  func channelPathsIncludeUID() {
    #expect(SocketDiscovery.productionSocketPath(uid: 1234) == "/tmp/codans-1234.sock")
    #expect(SocketDiscovery.developmentSocketPath(uid: 1234) == "/tmp/codans-dev-1234.sock")
  }

  @Test
  func defaultPathMatchesBuildChannel() {
    let path = SocketDiscovery.defaultSocketPath(uid: 1234)
    #if DEBUG
      #expect(path == "/tmp/codans-dev-1234.sock")
    #else
      #expect(path == "/tmp/codans-1234.sock")
    #endif
  }

  @Test
  func overrideWinsWhenNonEmpty() throws {
    #expect(try SocketDiscovery.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }

  @Test
  func emptyOverrideFallsBackToDefault() throws {
    let fallback = try SocketDiscovery.resolve(override: "")
    #if DEBUG
      #expect(fallback.hasPrefix("/tmp/codans-dev-"))
    #else
      #expect(fallback.hasPrefix("/tmp/codans-"))
    #endif
    #expect(fallback.hasSuffix(".sock"))
  }

  @Test
  func environmentIsConsultedWhenNoOverrideIsGiven() throws {
    let environment = ["CODANS_SOCKET_PATH": "/tmp/from-env.sock"]
    #expect(try SocketDiscovery.resolve(environment: environment) == "/tmp/from-env.sock")
    // The trap this guards: a caller forwarding its own empty flag passes an
    // explicit nil, which must not skip the environment.
    let flag: String? = nil
    #expect(
      try SocketDiscovery.resolve(override: flag, environment: environment) == "/tmp/from-env.sock")
  }

  @Test
  func explicitOverrideOutranksTheEnvironment() throws {
    let environment = ["CODANS_SOCKET_PATH": "/tmp/from-env.sock"]
    let resolved = try SocketDiscovery.resolve(override: "/tmp/flag.sock", environment: environment)
    #expect(resolved == "/tmp/flag.sock")
  }

  @Test
  func emptyEnvironmentValueFallsBackToTheBuildDefault() throws {
    let resolved = try SocketDiscovery.resolve(environment: ["CODANS_SOCKET_PATH": ""])
    #expect(resolved == SocketDiscovery.defaultSocketPath())
  }

  // MARK: - Channel rules

  /// Nothing typed into a development pane may reach the release app by
  /// accident, which is what happens when an agent follows documentation
  /// that says `codans` while sitting in a `codans-dev` pane.
  @Test
  func releaseCLIRefusesADevelopmentPane() {
    let pane = SocketDiscovery.developmentSocketPath(uid: 7)
    #expect(throws: SocketDiscovery.ForeignPaneRefusal(paneChannel: .development, socketPath: pane)) {
      try SocketDiscovery.resolve(environment: ["CODANS_SOCKET_PATH": pane], channel: .release, uid: 7)
    }
  }

  /// The developer's tool follows its name: run from a release pane it still
  /// drives the development app.
  @Test
  func developmentCLIIgnoresAReleasePaneAndDialsItsOwnSocket() throws {
    let pane = SocketDiscovery.productionSocketPath(uid: 7)
    let resolved = try SocketDiscovery.resolve(
      environment: ["CODANS_SOCKET_PATH": pane], channel: .development, uid: 7)
    #expect(resolved == SocketDiscovery.developmentSocketPath(uid: 7))
  }

  @Test
  func explicitSocketCrossesChannelsOnPurpose() throws {
    let pane = SocketDiscovery.developmentSocketPath(uid: 7)
    let release = SocketDiscovery.productionSocketPath(uid: 7)
    let resolved = try SocketDiscovery.resolve(
      override: release, environment: ["CODANS_SOCKET_PATH": pane], channel: .release, uid: 7)
    #expect(resolved == release)
  }

  @Test
  func customSocketPathsAreHonouredByBothChannels() throws {
    let environment = ["CODANS_SOCKET_PATH": "/tmp/isolated.sock"]
    #expect(try SocketDiscovery.resolve(environment: environment, channel: .release, uid: 7) == "/tmp/isolated.sock")
    #expect(
      try SocketDiscovery.resolve(environment: environment, channel: .development, uid: 7) == "/tmp/isolated.sock")
  }

  @Test
  func refusalNamesTheCommandToUseInstead() {
    let refusal = SocketDiscovery.ForeignPaneRefusal(
      paneChannel: .development, socketPath: "/tmp/codans-dev-7.sock")
    #expect(refusal.hint.contains("`codans-dev`"))
    #expect(refusal.message.contains("development build"))
    #expect(refusal.message.contains("`codans`"))
  }

  @Test
  func isReachableReturnsFalseForMissingPath() {
    let absent = "/tmp/codans-tests-\(UUID().uuidString).sock"
    #expect(SocketDiscovery.isReachable(path: absent) == false)
  }
}
