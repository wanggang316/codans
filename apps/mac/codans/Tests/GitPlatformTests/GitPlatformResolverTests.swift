import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The resolver gives each remote its Git Platform: an alias, the public host of a kind or a
/// host that kind's CLI is logged in to, the `ssh -G` HostName of an SSH remote; otherwise
/// none (ADR 0005 item 3).
struct GitPlatformResolverTests {
  @Test
  func githubDotComResolvesToGitHubWithoutAskingTheCLI() async {
    let resolver = GitPlatformResolver { _ in
      Issue.record("github.com must not need the logged-in hosts")
      return []
    }
    let repository = await resolver.resolve(RemoteInfo(host: "github.com", path: "wanggang316/codans"))
    #expect(repository == GitPlatformRepository(kind: .github, host: "github.com", path: "wanggang316/codans"))
  }

  @Test
  func aGHESHostThatGhIsLoggedInToResolvesToGitHub() async {
    let resolver = GitPlatformResolver { kind in kind == .github ? ["github.com", "GHE.example.com"] : [] }
    let repository = await resolver.resolve(RemoteInfo(host: "ghe.example.com", path: "platform/monorepo"))
    #expect(repository == GitPlatformRepository(kind: .github, host: "ghe.example.com", path: "platform/monorepo"))
  }

  @Test
  func anUnknownHostResolvesToNone() async {
    let resolver = GitPlatformResolver { kind in kind == .github ? ["github.com"] : ["gitlab.com"] }
    #expect(await resolver.resolve(RemoteInfo(host: "git.example.com", path: "group/sub/repo")) == nil)
  }

  // MARK: - glab step

  @Test
  func gitlabDotComResolvesToGitLabWhenGhDoesNotKnowIt() async {
    let resolver = GitPlatformResolver { kind in
      #expect(kind == .github, "gitlab.com must not need glab's logged-in hosts")
      return ["github.com"]
    }
    let repository = await resolver.resolve(RemoteInfo(host: "gitlab.com", path: "group/sub/repo"))
    #expect(repository == GitPlatformRepository(kind: .gitlab, host: "gitlab.com", path: "group/sub/repo"))
  }

  /// A self-managed instance with a port, as `glab auth status` lists it.
  @Test
  func aHostThatGlabIsLoggedInToResolvesToGitLab() async {
    let resolver = GitPlatformResolver { kind in
      kind == .github ? ["github.com"] : ["gitlab.com", "192.168.2.158:8929"]
    }
    let repository = await resolver.resolve(RemoteInfo(host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app"))
    #expect(
      repository
        == GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/nested/deep-app"))
  }

  /// GitHub is tried first (ADR 0004 item 2): a host both CLIs know is a GitHub host.
  @Test
  func aHostKnownToBothCLIsResolvesToGitHub() async {
    let resolver = GitPlatformResolver { _ in ["code.example.com"] }
    let repository = await resolver.resolve(RemoteInfo(host: "code.example.com", path: "team/repo"))
    #expect(repository?.kind == .github)
  }

  @Test
  func aHostGhIsLoggedInToWinsOverGitLabDotCom() async {
    let resolver = GitPlatformResolver { kind in kind == .github ? ["gitlab.com"] : [] }
    #expect(await resolver.resolve(RemoteInfo(host: "gitlab.com", path: "group/repo"))?.kind == .github)
  }

  @Test
  func loggedInHostsAreAskedOncePerKindUntilInvalidated() async {
    let calls = LockIsolated<[GitPlatformKind: Int]>([:])
    let resolver = GitPlatformResolver { kind in
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

  // MARK: - Git Platform aliases

  /// An alias is checked first, so the user can correct a host a CLI knows.
  @Test
  func anAliasWinsOverACLIHost() async {
    let resolver = GitPlatformResolver { kind in kind == .github ? ["code.example.com"] : ["gitlab.example.com"] }
    let alias = GitPlatformAlias(remoteHost: "code.example.com", kind: .gitlab, apiHost: "gitlab.example.com")
    #expect(
      await resolver.resolve(RemoteInfo(host: "Code.Example.com", path: "g/r"), aliases: [alias])
        == GitPlatformRepository(kind: .gitlab, host: "gitlab.example.com", path: "g/r"))
  }

  /// The API host is not logged in: the alias still resolves, so the fetch fails with
  /// the login message in the badge position.
  @Test
  func anAliasWithANotLoggedInAPIHostStillResolves() async {
    let resolver = GitPlatformResolver(
      hostsProvider: { _ in [] },
      sshHostName: { _ in
        Issue.record("an alias must not need ssh")
        return nil
      })
    let alias = GitPlatformAlias(remoteHost: "ssh.gitlab.example.com", kind: .gitlab, apiHost: "gitlab.example.com")
    #expect(
      await resolver.resolve(
        RemoteInfo(host: "ssh.gitlab.example.com", path: "g/r", isSSH: true), aliases: [alias])
        == GitPlatformRepository(kind: .gitlab, host: "gitlab.example.com", path: "g/r"))
  }

  /// `ssh://git@127.0.0.1:2224/…`: the port is the SSH port, so the alias `127.0.0.1`
  /// matches. An HTTPS port is the API port, so there it does not.
  @Test
  func anAliasWithoutAPortMatchesAnSSHRemoteWithItsSSHPort() async {
    let resolver = GitPlatformResolver { _ in [] }
    let alias = GitPlatformAlias(remoteHost: "127.0.0.1", kind: .gitlab, apiHost: "192.168.2.158:8929")
    #expect(
      await resolver.resolve(
        RemoteInfo(host: "127.0.0.1:2224", path: "codans-e2e/app", isSSH: true), aliases: [alias])
        == GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app"))
    #expect(
      await resolver.resolve(RemoteInfo(host: "127.0.0.1:2224", path: "codans-e2e/app"), aliases: [alias]) == nil)
  }

  @Test
  func anAliasForAnotherHostDoesNotApply() async {
    let resolver = GitPlatformResolver { kind in kind == .github ? ["github.com"] : [] }
    let alias = GitPlatformAlias(remoteHost: "gl", kind: .gitlab, apiHost: "192.168.2.158:8929")
    #expect(
      await resolver.resolve(RemoteInfo(host: "github.com", path: "w/r"), aliases: [alias])?.kind == .github)
  }

  // MARK: - ssh -G for every SSH remote

  /// `git@github-work:org/repo` with `Host github-work → HostName github.com`: GitHub at
  /// github.com, with no alias.
  @Test
  func anSSHConfigAliasResolvesUnderAutoToTheHostOfItsHostName() async {
    let resolver = GitPlatformResolver(
      hostsProvider: { kind in kind == .github ? ["github.com"] : ["192.168.2.158:8929"] },
      sshHostName: { alias in ["github-work": "github.com", "gl": "192.168.2.158"][alias] })
    #expect(
      await resolver.resolve(RemoteInfo(host: "github-work", path: "org/repo", isSSH: true))
        == GitPlatformRepository(kind: .github, host: "github.com", path: "org/repo"))
    #expect(
      await resolver.resolve(RemoteInfo(host: "gl", path: "codans-e2e/app", isSSH: true))
        == GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app"))
  }

  /// The SSH port of a self-managed instance is not its API port.
  @Test
  func anSSHPortRemoteResolvesToTheGitLabHostWithItsAPIPort() async {
    let resolver = GitPlatformResolver(
      hostsProvider: { kind in kind == .github ? ["github.com"] : ["192.168.2.158:8929"] },
      sshHostName: { $0 })
    #expect(
      await resolver.resolve(RemoteInfo(host: "192.168.2.158:2222", path: "codans-e2e/app", isSSH: true))
        == GitPlatformRepository(kind: .gitlab, host: "192.168.2.158:8929", path: "codans-e2e/app"))
  }

  /// No logged-in host or more than one with that name: none.
  @Test
  func anSSHHostWithNoSingleMatchResolvesToNone() async {
    let resolver = GitPlatformResolver(
      hostsProvider: { kind in
        kind == .gitlab ? ["code.example.com:8443", "code.example.com:9443"] : ["code.example.com"]
      },
      sshHostName: { alias in alias == "work" ? "code.example.com" : "nowhere.example.com" })
    #expect(await resolver.resolve(RemoteInfo(host: "work", path: "g/r", isSSH: true)) == nil)
    #expect(await resolver.resolve(RemoteInfo(host: "other", path: "g/r", isSSH: true)) == nil)
  }

  /// A host both CLIs are logged in to counts once, as GitHub, like the CLI steps.
  @Test
  func anSSHHostNameKnownToBothCLIsIsOneMatch() async {
    let resolver = GitPlatformResolver(
      hostsProvider: { _ in ["code.example.com"] },
      sshHostName: { _ in "code.example.com" })
    #expect(
      await resolver.resolve(RemoteInfo(host: "work", path: "g/r", isSSH: true))
        == GitPlatformRepository(kind: .github, host: "code.example.com", path: "g/r"))
  }

  /// An HTTPS port is the API port, so an HTTPS remote never runs `ssh -G`.
  @Test
  func anHTTPSRemoteDoesNotRunSSH() async {
    let resolver = GitPlatformResolver(
      hostsProvider: { _ in ["192.168.2.158:8929"] },
      sshHostName: { _ in
        Issue.record("an HTTPS remote must not ask ssh")
        return nil
      })
    #expect(await resolver.resolve(RemoteInfo(host: "192.168.2.158:9000", path: "g/r")) == nil)
  }

  @Test
  func sshResultsAreCachedUntilInvalidated() async {
    let calls = LockIsolated(0)
    let resolver = GitPlatformResolver(
      hostsProvider: { _ in [] },
      sshHostName: { host in
        calls.withValue { $0 += 1 }
        return host
      })
    let remote = RemoteInfo(host: "gl", path: "g/r", isSSH: true)
    _ = await resolver.resolve(remote)
    _ = await resolver.resolve(remote)
    #expect(calls.value == 1)
    await resolver.invalidate()
    _ = await resolver.resolve(remote)
    #expect(calls.value == 2)
  }
}
