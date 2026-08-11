import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct HierarchyHandlersResolveAliasTests {
  @Test
  func currentPaneResolvesViaPeerPID() async throws {
    let pane = PaneID()
    let handlers = Self.makeHandlers { pid in
      pid == 4242 ? pane : nil
    }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "current"))

    let outcome = await handlers.resolveAlias(params, peerPID: 4242)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.kind == .pane)
    #expect(result.id == pane.raw)
  }

  @Test
  func dotPronounResolvesLikeCurrent() async throws {
    let pane = PaneID()
    let handlers = Self.makeHandlers { _ in pane }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "."))

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == pane.raw)
  }

  @Test
  func peerAttributionWinsOverContextPaneID() async throws {
    let peerPane = PaneID()
    let envPane = PaneID()
    let handlers = Self.makeHandlers { _ in peerPane }
    let params = try JSONValue.encoded(
      IPC.AliasResolveRequest(kind: .pane, value: "current", contextPaneID: envPane)
    )

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == peerPane.raw)
  }

  @Test
  func unattributedCallerFallsBackToContextPaneID() async throws {
    let envPane = PaneID()
    let handlers = Self.makeHandlers { _ in nil }
    let params = try JSONValue.encoded(
      IPC.AliasResolveRequest(kind: .pane, value: "current", contextPaneID: envPane)
    )

    let outcome = await handlers.resolveAlias(params, peerPID: 1)
    let result: IPC.AliasResolveResult = try Self.decodeUnary(outcome)

    #expect(result.id == envPane.raw)
  }

  @Test
  func unattributableCurrentPaneIsNotFound() async throws {
    let handlers = Self.makeHandlers { _ in nil }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .pane, value: "current"))

    let outcome = await handlers.resolveAlias(params, peerPID: nil)

    guard case .failed(let error) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    guard case .notFound = error else {
      Issue.record("expected .notFound, got \(error)")
      return
    }
  }

  @Test
  func currentNonPaneKindIsUnsupported() async throws {
    let handlers = Self.makeHandlers { _ in PaneID() }
    let params = try JSONValue.encoded(IPC.AliasResolveRequest(kind: .worktree, value: "current"))

    let outcome = await handlers.resolveAlias(params, peerPID: 1)

    guard case .failed(let error) = outcome else {
      Issue.record("expected .failed, got \(outcome)")
      return
    }
    guard case .unsupported = error else {
      Issue.record("expected .unsupported, got \(error)")
      return
    }
  }

  // MARK: - Helpers

  private static func makeHandlers(
    callerPaneResolver: @escaping @MainActor (pid_t) -> PaneID?
  ) -> HierarchyHandlers {
    let manager = HierarchyManager(
      catalog: Catalog(projects: []),
      store: CatalogStore(fileURL: Self.tempURL()),
      runtime: FakeHierarchyRuntime()
    )
    return HierarchyHandlers(
      manager: manager,
      callerPaneResolver: callerPaneResolver
    )
  }

  private static func decodeUnary<T: Decodable>(_ outcome: RouterOutcome) throws -> T {
    guard case .unary(let value) = outcome else {
      Issue.record("expected unary response, got \(outcome)")
      throw TestError.unexpectedOutcome
    }
    return try value.decoded(as: T.self)
  }

  private static func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-resolve-alias-tests-\(UUID().uuidString).json")
  }

  private enum TestError: Error {
    case unexpectedOutcome
  }
}
