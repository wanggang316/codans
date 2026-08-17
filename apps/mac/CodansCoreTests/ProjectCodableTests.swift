import Foundation
import Testing

@testable import CodansCore

/// Exercises `Project.init(from:)` / `Project.encode(to:)`:
/// - The transient `loadState` is never encoded (so pre-Project-Management
///   catalogs round-trip byte-identical for unchanged Projects).
/// - Every decoded Project starts with `loadState == .loading`, regardless of
///   the value on the encoded Project.
struct ProjectCodableTests {
  @Test
  func decodeAssignsLoadStateLoading() throws {
    let project = Project(
      name: "repo",
      rootPath: "/tmp/repo",
      gitRoot: "/tmp/repo",
      loadState: .ready
    )
    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded.loadState == .loading)
    #expect(decoded.id == project.id)
    #expect(decoded.name == project.name)
    #expect(decoded.rootPath == project.rootPath)
    #expect(decoded.gitRoot == project.gitRoot)
  }

  @Test
  func encodeOmitsLoadStateKey() throws {
    let project = Project(
      name: "repo",
      rootPath: "/tmp/repo",
      loadState: .failed(reason: "missing")
    )
    let data = try JSONEncoder().encode(project)
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    #expect(object != nil)
    #expect(object?["loadState"] == nil)
  }

  @Test
  func roundTripMatchesCatalogShape() throws {
    // Pre-Project-Management catalogs never had `loadState`. Encode a Project
    // with a non-default runtime load state, then compare the encoded JSON
    // dictionary against a fresh Project without the load state — they must
    // match key-for-key so no catalog migration is required.
    let project = Project(
      name: "repo",
      rootPath: "/tmp/repo",
      gitRoot: "/tmp/repo",
      loadState: .failed(reason: "missing")
    )
    let runtimeData = try JSONEncoder().encode(project)
    let runtimeObject = try JSONSerialization.jsonObject(with: runtimeData, options: []) as? [String: Any]

    let preMgmtData = try JSONEncoder().encode(Project(
      id: project.id,
      name: project.name,
      rootPath: project.rootPath,
      gitRoot: project.gitRoot,
      worktrees: project.worktrees,
      selectedWorktreeID: project.selectedWorktreeID,
      addedAt: project.addedAt,
      lastActiveAt: project.lastActiveAt
    ))
    let preMgmtObject = try JSONSerialization.jsonObject(with: preMgmtData, options: []) as? [String: Any]

    #expect(runtimeObject != nil)
    #expect(preMgmtObject != nil)
    #expect(NSDictionary(dictionary: runtimeObject ?? [:])
      .isEqual(to: preMgmtObject ?? [:]))
  }

  @Test
  func localProjectEncodesNoRemoteHostKey() throws {
    // A local project must round-trip byte-identical: the new `remoteHost` key is
    // absent so pre-Server catalogs are untouched.
    let project = Project(name: "repo", rootPath: "/tmp/repo", gitRoot: "/tmp/repo")
    let data = try JSONEncoder().encode(project)
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    #expect(object?["remoteHost"] == nil)
  }

  @Test
  func serverProjectRoundTripsRemoteHost() throws {
    let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
    let project = Project(
      name: "app",
      rootPath: "/srv/app",
      gitRoot: "/srv/app",
      remoteHost: host
    )
    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded.remoteHost == host)
    #expect(decoded.isRemote)
    #expect(decoded.kind == .server)
    #expect(decoded.rootPath == "/srv/app")
  }
}
