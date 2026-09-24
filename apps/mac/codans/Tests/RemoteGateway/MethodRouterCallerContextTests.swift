import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

/// The router is the single choke point for remote authorization: a call
/// outside the device's tier is refused with `forbidden` before any handler
/// runs, and local callers are never gated.
@MainActor
struct MethodRouterCallerContextTests {
  private static let device = UUID()

  @Test
  func readOnlyDeviceIsRefusedEveryInteractiveMethod() async {
    let router = Self.makeRouter()
    let interactive = IPC.Method.allCases.filter { $0.remoteTier == .interactive }
    #expect(interactive.contains(.terminalSendInput))
    for method in interactive {
      let outcome = await router.route(
        IPC.Request(id: "r", method: method),
        context: .remote(deviceID: Self.device, permission: .readOnly))
      #expect(Self.isForbidden(outcome), "\(method.rawValue) reached a handler for a read-only device")
    }
  }

  @Test
  func localOnlyMethodsAreRefusedAtEveryPermission() async {
    let router = Self.makeRouter()
    let localOnly = IPC.Method.allCases.filter { $0.remoteTier == .localOnly }
    #expect(localOnly.contains(.systemQuit))
    for permission in IPC.RemotePermission.allCases {
      for method in localOnly {
        let outcome = await router.route(
          IPC.Request(id: "r", method: method),
          context: .remote(deviceID: Self.device, permission: permission))
        #expect(Self.isForbidden(outcome), "\(method.rawValue) reached a handler for \(permission.rawValue)")
      }
    }
  }

  @Test
  func tierAllowedMethodsPassTheGate() async {
    let router = Self.makeRouter()
    for method in IPC.Method.allCases where method.remoteTier == .readOnly {
      let outcome = await router.route(
        IPC.Request(id: "r", method: method),
        context: .remote(deviceID: Self.device, permission: .readOnly))
      #expect(!Self.isForbidden(outcome), "\(method.rawValue) refused for a read-only device")
    }
    for method in IPC.Method.allCases where method.remoteTier == .interactive {
      let outcome = await router.route(
        IPC.Request(id: "r", method: method),
        context: .remote(deviceID: Self.device, permission: .interactive))
      #expect(!Self.isForbidden(outcome), "\(method.rawValue) refused for an interactive device")
    }
  }

  @Test
  func pingAnswersForAReadOnlyDevice() async {
    let outcome = await Self.makeRouter().route(
      IPC.Request(id: "r", method: .systemPing),
      context: .remote(deviceID: Self.device, permission: .readOnly))
    guard case .unary = outcome else {
      Issue.record("expected a unary ping result, got \(outcome)")
      return
    }
  }

  @Test
  func localCallersAreNeverGated() async {
    let router = Self.makeRouter()
    for method in [IPC.Method.terminalSendInput, .terminalBroadcastInput, .hierarchyRemoveProject] {
      let outcome = await router.route(IPC.Request(id: "r", method: method), context: .local(peerPID: nil))
      #expect(!Self.isForbidden(outcome), "\(method.rawValue) refused for a local caller")
    }
  }

  @Test
  func revokedDeviceIsRefusedOnTheConnection() async throws {
    let (reader, feed) = AsyncStream<Data>.makeStream()
    let responses = ResponseCollector()
    let connection = SocketConnection(
      router: Self.makeRouter(),
      reader: reader,
      write: { await responses.append($0) },
      close: {},
      context: { nil }
    )
    let serve = Task { await connection.serve() }
    let hello = try JSONValue.encoded(HelloRequest(clientVersion: "1", clientBinary: "test"))
    feed.yield(try Framing.encode(JSONEncoder().encode(IPC.Request(id: "h", method: .systemHello, params: hello))))
    feed.finish()
    await serve.value
    let response = try #require(await responses.decoded().first)
    #expect(response.error == .forbidden(reason: "this device is no longer paired"))
  }

  // MARK: - Helpers

  private static func makeRouter() -> MethodRouter {
    MethodRouter(systemHandlers: SystemHandlers(versions: .init(server: "1", appBundle: "1")))
  }

  private static func isForbidden(_ outcome: RouterOutcome) -> Bool {
    if case .failed(.forbidden) = outcome { return true }
    return false
  }
}

private actor ResponseCollector {
  private var buffer = Data()

  func append(_ data: Data) { buffer.append(data) }

  func decoded() -> [IPC.Response] {
    var remaining = buffer
    var responses: [IPC.Response] = []
    while let frame = try? Framing.decode(from: &remaining),
      let response = try? JSONDecoder().decode(IPC.Response.self, from: frame)
    {
      responses.append(response)
    }
    return responses
  }
}
