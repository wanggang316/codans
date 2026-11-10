import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Records the locations the shared route is asked to resolve. Resolves every
/// location to This Mac, so no test opens an SSH connection.
private actor ResolvedLocations {
  private(set) var urls: [URL] = []
  func record(_ url: URL) { urls.append(url) }
}

/// Coverage for the one Remote Project routing source (`GitRemoteRoute`) and
/// for the local runners' refusal of a Remote Project location (#508).
///
/// Serialized: the tests bind the process-wide `GitRemoteRoute.shared`.
@Suite(.serialized)
struct GitRemoteRouteTests {
  private static func remoteLocation() -> URL {
    GitLocation.url(path: "/srv/app", hostID: HostID(raw: UUID()))
  }

  /// The Settings page reads `@Dependency(GitWorktreeClient.self)` straight
  /// from the view, outside any store. That read must resolve to a client
  /// that consults the shared route; an unrouted client sends the Remote
  /// Project location to the local runner.
  @Test
  func viewSideWorktreeClientConsultsSharedRoute() async {
    let resolved = ResolvedLocations()
    GitRemoteRoute.shared.bind { url in
      await resolved.record(url)
      return nil
    }
    defer { GitRemoteRoute.shared.bind(nil) }
    let location = Self.remoteLocation()

    await withDependencies {
      $0.context = .live
    } operation: {
      @Dependency(GitWorktreeClient.self) var client
      _ = try? await client.branchRefs(location)
      _ = try? await client.defaultRemoteBranchRef(location)
    }

    #expect(await resolved.urls.filter { $0 == location }.count == 2)
  }

  @Test
  func viewSideGitServiceClientConsultsSharedRoute() async {
    let resolved = ResolvedLocations()
    GitRemoteRoute.shared.bind { url in
      await resolved.record(url)
      return nil
    }
    defer { GitRemoteRoute.shared.bind(nil) }
    let location = Self.remoteLocation()

    await withDependencies {
      $0.context = .live
    } operation: {
      @Dependency(GitServiceClient.self) var client
      _ = try? await client.listAllBranches(location)
    }

    #expect(await resolved.urls.contains(location))
  }

  /// A Remote Project location that no route resolves reaches the local
  /// runner. It must fail with an error, not raise an Objective-C exception
  /// from `Process.currentDirectoryURL`.
  @Test
  func unresolvedRemoteLocationThrowsFromLocalWorktreeRunner() async {
    let client = GitWorktreeClient.makeLive()
    let location = Self.remoteLocation()

    await #expect(throws: GitWorktreeError.self) {
      _ = try await client.branchRefs(location)
    }
    #expect((try? await client.defaultRemoteBranchRef(location)) == nil)
  }

  @Test
  func unresolvedRemoteLocationThrowsFromLocalGitService() async {
    let service = Git.makeService()
    let location = Self.remoteLocation()

    await #expect(throws: (any Error).self) {
      _ = try await service.listAllBranches(at: location)
    }
  }
}
