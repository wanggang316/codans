import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The resolver gives each remote its Code Host: the public host of a kind, or a host
/// that kind's CLI is logged in to; otherwise none (ADR 0004 item 2).
struct CodeHostResolverTests {
  @Test
  func githubDotComResolvesToGitHubWithoutAskingTheCLI() async {
    let resolver = CodeHostResolver { _ in
      Issue.record("github.com must not need the logged-in hosts")
      return []
    }
    let repository = await resolver.resolve(RemoteInfo(host: "github.com", path: "wanggang316/codans"))
    #expect(repository == CodeHostRepository(kind: .github, host: "github.com", path: "wanggang316/codans"))
  }

  @Test
  func aGHESHostThatGhIsLoggedInToResolvesToGitHub() async {
    let resolver = CodeHostResolver { kind in kind == .github ? ["github.com", "GHE.example.com"] : [] }
    let repository = await resolver.resolve(RemoteInfo(host: "ghe.example.com", path: "platform/monorepo"))
    #expect(repository == CodeHostRepository(kind: .github, host: "ghe.example.com", path: "platform/monorepo"))
  }

  @Test
  func anUnknownHostResolvesToNone() async {
    let resolver = CodeHostResolver { _ in ["github.com"] }
    #expect(await resolver.resolve(RemoteInfo(host: "gitlab.example.com", path: "group/sub/repo")) == nil)
  }

  @Test
  func loggedInHostsAreAskedOnceUntilInvalidated() async {
    let calls = LockIsolated(0)
    let resolver = CodeHostResolver { _ in
      calls.withValue { $0 += 1 }
      return []
    }
    let remote = RemoteInfo(host: "gitlab.example.com", path: "group/repo")
    _ = await resolver.resolve(remote)
    _ = await resolver.resolve(remote)
    #expect(calls.value == 1)
    await resolver.invalidate()
    _ = await resolver.resolve(remote)
    #expect(calls.value == 2)
  }
}
