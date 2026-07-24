import Foundation
import Testing

@testable import CodansCore

struct RemoteHostTests {
  @Test
  func sshDestinationIncludesUserWhenPresent() {
    let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
    #expect(host.sshDestination == "alice@example.com")
  }

  @Test
  func sshDestinationOmitsEmptyUser() {
    #expect(RemoteHost(alias: "example.com").sshDestination == "example.com")
    #expect(RemoteHost(alias: "example.com", username: "").sshDestination == "example.com")
  }

  @Test
  func sshOptionArgumentsCarryPortOnlyWhenSet() {
    #expect(RemoteHost(alias: "h").sshOptionArguments == [])
    #expect(RemoteHost(alias: "h", port: 2222).sshOptionArguments == ["-p", "2222"])
  }

  @Test
  func hasNonDefaultPortFoldsDefaults() {
    #expect(RemoteHost(alias: "h").hasNonDefaultPort == false)
    #expect(RemoteHost(alias: "h", port: 22).hasNonDefaultPort == false)
    #expect(RemoteHost(alias: "h", port: 2222).hasNonDefaultPort)
  }

  @Test
  func displayAuthorityHidesDefaultPort() {
    #expect(RemoteHost(alias: "h", username: "u", port: 22).displayAuthority == "u@h")
    #expect(RemoteHost(alias: "h", username: "u", port: 2222).displayAuthority == "u@h:2222")
    #expect(RemoteHost(alias: "h").displayAuthority == "h")
  }

  @Test
  func authorityAlwaysFoldsPort() {
    #expect(RemoteHost(alias: "h", username: "u", port: 22).authority == "u@h:22")
    #expect(RemoteHost(alias: "h").authority == "h")
  }

  @Test
  func authorityRoundTripsThroughInit() {
    let cases = [
      RemoteHost(alias: "example.com", username: "alice", port: 2222),
      RemoteHost(alias: "example.com"),
      RemoteHost(alias: "example.com", username: "bob"),
      RemoteHost(alias: "10.0.0.5", port: 22),
    ]
    for host in cases {
      let parsed = RemoteHost(authority: host.authority)
      #expect(parsed == host)
    }
  }

  @Test
  func initFromAuthorityParsesForms() {
    #expect(RemoteHost(authority: "alice@example.com:2222")
      == RemoteHost(alias: "example.com", username: "alice", port: 2222))
    #expect(RemoteHost(authority: "example.com")
      == RemoteHost(alias: "example.com"))
    #expect(RemoteHost(authority: "  ") == nil)
    #expect(RemoteHost(authority: "@host") == RemoteHost(alias: "host"))
  }

  @Test
  func ipv6AuthorityKeepsBracketedHost() {
    let host = RemoteHost(alias: "::1", username: "u", port: 2222)
    #expect(host.authority == "u@[::1]:2222")
    #expect(RemoteHost(authority: host.authority) == host)
    // The ssh CLI destination stays unbracketed.
    #expect(host.sshDestination == "u@::1")
  }

  @Test
  func codableRoundTrip() throws {
    let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
    let data = try JSONEncoder().encode(host)
    let decoded = try JSONDecoder().decode(RemoteHost.self, from: data)
    #expect(decoded == host)
  }
}
