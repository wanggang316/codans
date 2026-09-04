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
  func overrideWinsWhenNonEmpty() {
    #expect(SocketDiscovery.resolve(override: "/tmp/custom.sock") == "/tmp/custom.sock")
  }

  @Test
  func emptyOverrideFallsBackToDefault() {
    let fallback = SocketDiscovery.resolve(override: "")
    #if DEBUG
      #expect(fallback.hasPrefix("/tmp/codans-dev-"))
    #else
      #expect(fallback.hasPrefix("/tmp/codans-"))
    #endif
    #expect(fallback.hasSuffix(".sock"))
  }

  @Test
  func environmentIsConsultedWhenNoOverrideIsGiven() {
    let environment = ["CODANS_SOCKET_PATH": "/tmp/from-env.sock"]
    #expect(SocketDiscovery.resolve(environment: environment) == "/tmp/from-env.sock")
    // The trap this guards: a caller forwarding its own empty flag passes an
    // explicit nil, which must not skip the environment.
    let flag: String? = nil
    #expect(SocketDiscovery.resolve(override: flag, environment: environment) == "/tmp/from-env.sock")
  }

  @Test
  func explicitOverrideOutranksTheEnvironment() {
    let environment = ["CODANS_SOCKET_PATH": "/tmp/from-env.sock"]
    let resolved = SocketDiscovery.resolve(override: "/tmp/flag.sock", environment: environment)
    #expect(resolved == "/tmp/flag.sock")
  }

  @Test
  func emptyEnvironmentValueFallsBackToTheBuildDefault() {
    let resolved = SocketDiscovery.resolve(environment: ["CODANS_SOCKET_PATH": ""])
    #expect(resolved == SocketDiscovery.defaultSocketPath())
  }

  @Test
  func isReachableReturnsFalseForMissingPath() {
    let absent = "/tmp/codans-tests-\(UUID().uuidString).sock"
    #expect(SocketDiscovery.isReachable(path: absent) == false)
  }
}
