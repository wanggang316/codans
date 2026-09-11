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
  func iconlessProjectEncodesNoIconKey() throws {
    // Same contract every optional Project field carries: a Project the user
    // never re-iconed must round-trip byte-identical, so pre-HAN-144 catalogs
    // gain no key and need no migration.
    let project = Project(name: "repo", rootPath: "/tmp/repo", gitRoot: "/tmp/repo")
    let data = try JSONEncoder().encode(project)
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    #expect(object?["icon"] == nil)
  }

  @Test
  func iconRoundTrips() throws {
    let project = Project(
      name: "repo",
      rootPath: "/tmp/repo",
      gitRoot: "/tmp/repo",
      icon: .symbol("shippingbox")
    )
    let data = try JSONEncoder().encode(project)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded.icon == .symbol("shippingbox"))
  }

  /// A malformed `icon` must degrade to the default folder glyph rather than
  /// throwing: `Project.init(from:)` runs inside the `catalog.json` decode, so
  /// a throw over a cosmetic value would take the user's whole catalog with it.
  @Test
  func malformedIconDecodesToNilInsteadOfThrowing() throws {
    let json = """
      {"id":{"raw":"\(UUID().uuidString)"},"name":"repo","rootPath":"/tmp/repo",\
      "worktrees":[],"icon":"bogus"}
      """
    let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
    #expect(decoded.icon == nil)
    #expect(decoded.name == "repo")
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
