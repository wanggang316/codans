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

  @Test
  func uuidValueIsFastPathNoRPC() async throws {
    let uuid = UUID()
    let resolved = try await AliasResolver.resolve(
      uuid.uuidString,
      kind: .pane,
      env: [:],
      client: Self.failingClient()
    )
    #expect(resolved == uuid)
  }

  @Test
  func currentPronounReadsEnv() async throws {
    let uuid = UUID()
    let resolved = try await AliasResolver.resolve(
      "current",
      kind: .pane,
      env: ["CODANS_PANE_ID": uuid.uuidString],
      client: Self.failingClient()
    )
    #expect(resolved == uuid)
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
