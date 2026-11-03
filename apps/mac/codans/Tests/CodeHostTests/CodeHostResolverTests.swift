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
    let resolver = CodeHostResolver { kind in kind == .github ? ["github.com"] : ["gitlab.com"] }
    #expect(await resolver.resolve(RemoteInfo(host: "git.example.com", path: "group/sub/repo")) == nil)
  }

  // MARK: - glab step

  @Test
  func gitlabDotComResolvesToGitLabWhenGhDoesNotKnowIt() async {
    let resolver = CodeHostResolver { kind in
      #expect(kind == .github, "gitlab.com must not need glab's logged-in hosts")
      return ["github.com"]
    }
    let repository = await resolver.resolve(RemoteInfo(host: "gitlab.com", path: "group/sub/repo"))
    #expect(repository == CodeHostRepository(kind: .gitlab, host: "gitlab.com", path: "group/sub/repo"))
  }

  /// A self-managed instance with a port, as `glab auth status` lists it.
  @Test
  func aHostThatGlabIsLoggedInToResolvesToGitLab() async {
    let resolver = CodeHostResolver { kind in
      kind == .github ? ["github.com"] : ["gitlab.com", "192.168.2.158:8929"]
    }
    let repository = await resolver.resolve(RemoteInfo(host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app"))
    #expect(
      repository
        == CodeHostRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app"))
  }

  /// GitHub is tried first (ADR 0004 item 2): a host both CLIs know is a GitHub host.
  @Test
  func aHostKnownToBothCLIsResolvesToGitHub() async {
    let resolver = CodeHostResolver { _ in ["code.example.com"] }
    let repository = await resolver.resolve(RemoteInfo(host: "code.example.com", path: "team/repo"))
    #expect(repository?.kind == .github)
  }

  @Test
  func aHostGhIsLoggedInToWinsOverGitLabDotCom() async {
    let resolver = CodeHostResolver { kind in kind == .github ? ["gitlab.com"] : [] }
    #expect(await resolver.resolve(RemoteInfo(host: "gitlab.com", path: "group/repo"))?.kind == .github)
  }

  @Test
  func loggedInHostsAreAskedOncePerKindUntilInvalidated() async {
    let calls = LockIsolated<[CodeHostKind: Int]>([:])
    let resolver = CodeHostResolver { kind in
      calls.withValue { $0[kind, default: 0] += 1 }
      return []
    }
    let remote = RemoteInfo(host: "git.example.com", path: "group/repo")
    _ = await resolver.resolve(remote)
    _ = await resolver.resolve(remote)
    #expect(calls.value == [.github: 1, .gitlab: 1])
    await resolver.invalidate()
    _ = await resolver.resolve(remote)
    #expect(calls.value == [.github: 2, .gitlab: 2])
  }

  // MARK: - Project choice

  /// An SSH alias (`Host gl` in `~/.ssh/config`) that neither CLI knows: the Project
  /// choice gives the Code Host.
  @Test(arguments: CodeHostKind.allCases)
  func theProjectChoiceGivesTheCodeHostOfAHostNoCLIKnows(choice: CodeHostKind) async {
    let resolver = CodeHostResolver { kind in kind == .github ? ["github.com"] : ["192.168.2.158:8929"] }
    let repository = await resolver.resolve(RemoteInfo(host: "gl", path: "codans-e2e/app"), choice: choice)
    #expect(repository == CodeHostRepository(kind: choice, host: "gl", path: "codans-e2e/app"))
  }

  /// The choice comes after the CLI steps (ADR 0004 item 2).
  @Test
  func theCLIStepsWinOverTheProjectChoice() async {
    let resolver = CodeHostResolver { kind in kind == .github ? [] : ["192.168.2.158:8929"] }
    #expect(await resolver.resolve(RemoteInfo(host: "github.com", path: "w/r"), choice: .gitlab)?.kind == .github)
    #expect(
      await resolver.resolve(RemoteInfo(host: "192.168.2.158:8929", path: "g/r"), choice: .github)?.kind == .gitlab)
  }

  @Test
  func autoWithNoMatchResolvesToNone() async {
    let resolver = CodeHostResolver { _ in [] }
    #expect(await resolver.resolve(RemoteInfo(host: "gl", path: "codans-e2e/app"), choice: nil) == nil)
  }
}
