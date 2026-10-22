import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

@MainActor
struct AliasResolverTests {
  /// Sentinel thrown by the test helper below when the resolver
  /// evaluates the autoclosure. The UUID and context-env paths must not
  /// dial the client; if they do, this error escapes and the test
  /// fails loudly instead of racing against a real RPCClient
  /// construction.
  struct ResolverShouldNotDialClient: Swift.Error, Equatable {}

  @Test(arguments: [IPC.AliasResolveRequest.Kind.project, .worktree, .tag])
  func containerUUIDIsFastPathNoRPC(kind: IPC.AliasResolveRequest.Kind) async throws {
    let uuid = UUID()
    let match = try await AliasResolver.resolveMatch(
      uuid.uuidString,
      kind: kind,
      env: [:],
      client: Self.failingClient()
    )
    #expect(match == AliasResolver.Match(id: uuid, matched: nil))
  }

  /// A Pane, Tab, or Content UUID can name any of the three levels, so it
  /// always goes to the server, which converts it to the requested level
  /// and reports which level the value named.
  @Test(arguments: [
    (IPC.AliasResolveRequest.Kind.pane, IPC.AliasResolveRequest.Kind.tab),
    (.tab, .content),
    (.content, .pane),
    (.pane, .pane),
  ])
  func sessionLevelUUIDRoundTripsForConversion(
    kind: IPC.AliasResolveRequest.Kind, named: IPC.AliasResolveRequest.Kind
  ) async throws {
    let given = UUID()
    let converted = UUID()
    let client = Self.scriptedClient { request in
      #expect(request.kind == kind)
      #expect(request.value == given.uuidString)
      return IPC.AliasResolveResult(kind: kind, id: converted, matched: named)
    }
    defer { Task { await client.shutdown() } }
    let match = try await AliasResolver.resolveMatch(
      given.uuidString, kind: kind, env: ["CODANS_PANE_ID": UUID().uuidString], client: client)
    #expect(match == AliasResolver.Match(id: converted, matched: named))
  }

  @Test
  func handlesRoundTripWithTheirOwnLevel() async throws {
    let paneID = UUID()
    let client = Self.scriptedClient { request in
      #expect(request.kind == .pane)
      #expect(request.value == "t4")
      return IPC.AliasResolveResult(kind: .pane, id: paneID, matched: .tab)
    }
    defer { Task { await client.shutdown() } }
    let match = try await AliasResolver.resolveMatch("t4", kind: .pane, env: [:], client: client)
    #expect(match == AliasResolver.Match(id: paneID, matched: .tab))
  }

  @Test
  func currentPronounReadsEnv() async throws {
    let uuid = UUID()
    let match = try await AliasResolver.resolveMatch(
      "current",
      kind: .pane,
      env: ["CODANS_PANE_ID": uuid.uuidString],
      client: Self.failingClient()
    )
    #expect(match == AliasResolver.Match(id: uuid, matched: .pane))
  }

  /// Each level reads its own variable: no variable stands in for another.
  @Test
  func currentPaneTabAndContentReadTheirOwnEnv() async throws {
    let paneID = UUID()
    let tabID = UUID()
    let contentID = UUID()
    let env = [
      "CODANS_PANE_ID": paneID.uuidString,
      "CODANS_TAB_ID": tabID.uuidString,
      "CODANS_CONTENT_ID": contentID.uuidString,
    ]
    let pane = try await AliasResolver.resolve("current", kind: .pane, env: env, client: Self.failingClient())
    #expect(pane == paneID)
    let tab = try await AliasResolver.resolve("current", kind: .tab, env: env, client: Self.failingClient())
    #expect(tab == tabID)
    let content = try await AliasResolver.resolve(
      "current", kind: .content, env: env, client: Self.failingClient())
    #expect(content == contentID)
  }

  @Test
  func callerContextIsTheContentIDOnly() {
    let contentID = UUID()
    let paneID = UUID()
    #expect(
      AliasResolver.callerContentID(env: [
        "CODANS_CONTENT_ID": contentID.uuidString, "CODANS_PANE_ID": paneID.uuidString,
      ]) == ContentID(raw: contentID))
    #expect(AliasResolver.callerContentID(env: ["CODANS_PANE_ID": paneID.uuidString]) == nil)
    #expect(AliasResolver.callerContentID(env: [:]) == nil)
  }

  @Test
  func dotPronounReadsEnv() async throws {
    let uuid = UUID()
    let resolved = try await AliasResolver.resolve(
      ".",
      kind: .project,
      env: ["CODANS_PROJECT_ID": uuid.uuidString],
      client: Self.failingClient()
    )
    #expect(resolved == uuid)
  }

  @Test
  func currentNonPaneWithoutEnvRoutesToServer() async throws {
    // No CODANS_WORKTREE_ID in the env: the worktree pronoun must fall
    // through to the server, which derives it from the calling pane.
    let targetID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .hierarchyResolveAlias)
      let request = try real.params.decoded(as: IPC.AliasResolveRequest.self)
      #expect(request.kind == .worktree)
      #expect(request.value == "current")
      let body = try JSONEncoder().encode(
        IPC.AliasResolveResult(kind: .worktree, id: targetID)
      )
      let resultJSON = try JSONDecoder().decode(JSONValue.self, from: body)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: resultJSON),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    let resolved = try await AliasResolver.resolve(
      "current",
      kind: .worktree,
      env: [:],
      client: client
    )
    #expect(resolved == targetID)
  }

  @Test
  func serverResolveCarriesCallerContentAsContext() async throws {
    let contentID = UUID()
    let targetID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      let request = try real.params.decoded(as: IPC.AliasResolveRequest.self)
      #expect(request.kind == .content)
      #expect(request.contextContentID == ContentID(raw: contentID))
      let body = try JSONEncoder().encode(IPC.AliasResolveResult(kind: .content, id: targetID))
      let resultJSON = try JSONDecoder().decode(JSONValue.self, from: body)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: resultJSON),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    let resolved = try await AliasResolver.resolve(
      "@reviewer",
      kind: .content,
      env: ["CODANS_CONTENT_ID": contentID.uuidString],
      client: client
    )
    #expect(resolved == targetID)
  }

  @Test
  func currentPaneWithoutEnvRoutesToServer() async throws {
    // No CODANS_PANE_ID in the env: the pane pronoun must fall through
    // to the server, which attributes the caller from the connection's
    // kernel peer PID.
    let targetID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .hierarchyResolveAlias)
      let request = try real.params.decoded(as: IPC.AliasResolveRequest.self)
      #expect(request.kind == .pane)
      #expect(request.value == "current")
      let body = try JSONEncoder().encode(
        IPC.AliasResolveResult(kind: .pane, id: targetID)
      )
      let resultJSON = try JSONDecoder().decode(JSONValue.self, from: body)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: resultJSON),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    let resolved = try await AliasResolver.resolve(
      "current",
      kind: .pane,
      env: [:],
      client: client
    )
    #expect(resolved == targetID)
  }

  @Test
  func labelRoutesToServerAndReturnsResolvedID() async throws {
    let targetID = UUID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .hierarchyResolveAlias)
      let body = try JSONEncoder().encode(
        IPC.AliasResolveResult(kind: .pane, id: targetID)
      )
      let resultJSON = try JSONDecoder().decode(JSONValue.self, from: body)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: resultJSON),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
    defer { Task { await client.shutdown() } }

    let resolved = try await AliasResolver.resolve(
      "@agent",
      kind: .pane,
      env: [:],
      client: client
    )
    #expect(resolved == targetID)
  }

  /// Throws `ResolverShouldNotDialClient` when evaluated. Wrapped by
  /// the autoclosure at the call site, so this body runs only if the
  /// resolver actually dials.
  private static func failingClient() throws -> RPCClient {
    throw ResolverShouldNotDialClient()
  }

  /// A client whose server answers one `hierarchy.resolveAlias` with
  /// `answer(request)`.
  private static func scriptedClient(
    _ answer: @escaping @Sendable (IPC.AliasResolveRequest) -> IPC.AliasResolveResult
  ) -> RPCClient {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .hierarchyResolveAlias)
      let request = try real.params.decoded(as: IPC.AliasResolveRequest.self)
      let body = try JSONEncoder().encode(answer(request))
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: try JSONDecoder().decode(JSONValue.self, from: body)),
      ]
    }
    return RPCClient(transport: transport, versions: .init(clientVersion: "0.3.0"))
  }
}

struct AliasResolverPathShapeTests {
  @Test
  func pathShapedWorktreeValuesBecomeAbsolute() {
    #expect(AliasResolver.absolutePathIfPathShaped("/a/b", cwd: "/cwd") == "/a/b")
    #expect(AliasResolver.absolutePathIfPathShaped("./x", cwd: "/cwd") == "/cwd/x")
    #expect(AliasResolver.absolutePathIfPathShaped("../x", cwd: "/cwd/sub") == "/cwd/x")
    #expect(AliasResolver.absolutePathIfPathShaped("..", cwd: "/cwd/sub") == "/cwd")
    #expect(AliasResolver.absolutePathIfPathShaped("~/x", cwd: "/cwd").hasSuffix("/x"))
    #expect(!AliasResolver.absolutePathIfPathShaped("~/x", cwd: "/cwd").hasPrefix("~"))
  }

  @Test
  func namesAndBranchesAreLeftAlone() {
    for value in ["main", "bugfix/menu", "feature/a/b", "current", ".", "MainWT"] {
      #expect(AliasResolver.absolutePathIfPathShaped(value, cwd: "/cwd") == value)
    }
  }
}
