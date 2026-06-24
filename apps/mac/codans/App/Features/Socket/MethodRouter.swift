import Foundation
import CodansCore
import CodansIPC
import os

/// Dispatch target for a streaming request. Handlers that respond with
/// `.streaming` provide a subscribe closure that the connection drains
/// frame-by-frame until either side closes.
public enum RouterOutcome: Sendable {
  case unary(JSONValue)
  case streaming(@Sendable () -> AsyncStream<JSONValue>)
  case failed(IPCError)
}

/// Protocol-level router: consumes typed requests, produces typed results.
/// The `SocketConnection` actor owns the wire encoding; the router owns
/// the method-to-handler mapping.
@MainActor
public final class MethodRouter {
  private let systemHandlers: SystemHandlers
  private let hierarchyHandlers: HierarchyHandlers?
  private let terminalHandlers: TerminalHandlers?
  private let editorHandlers: EditorHandlers?
  private let logger = Logger(subsystem: "com.gumpw.codans.ipc", category: "router")

  init(
    systemHandlers: SystemHandlers,
    hierarchyHandlers: HierarchyHandlers? = nil,
    terminalHandlers: TerminalHandlers? = nil,
    editorHandlers: EditorHandlers? = nil
  ) {
    self.systemHandlers = systemHandlers
    self.hierarchyHandlers = hierarchyHandlers
    self.terminalHandlers = terminalHandlers
    self.editorHandlers = editorHandlers
  }

  /// Route one decoded request to the appropriate handler. The handshake
  /// verb `system.hello` is routed here alongside other `system.*` calls.
  /// Unknown methods produce `RouterOutcome.failed(.unknownMethod)`.
  public func route(_ request: IPC.Request) async -> RouterOutcome {
    logger.debug("route \(request.method.rawValue, privacy: .public) id=\(request.id, privacy: .public)")
    if let outcome = await routeSystem(request) { return outcome }
    if let outcome = await routeHierarchy(request) { return outcome }
    if let outcome = await routePane(request) { return outcome }
    if let outcome = await routeTerminal(request) { return outcome }
    if let outcome = await routeEditor(request) { return outcome }
    return notWired(request.method)
  }

  /// `pane.*` namespace — explicit-termination verbs that own the zmx
  /// daemon lifecycle. Lives next to `hierarchy.*` because both share
  /// `HierarchyHandlers`, but routed separately so the wire-namespace
  /// split (`pane.close` vs `hierarchy.closePane`) shows up in the
  /// dispatch surface.
  private func routePane(_ request: IPC.Request) async -> RouterOutcome? {
    guard let h = hierarchyHandlers else { return nil }
    switch request.method {
    case .paneClose: return await h.paneClose(request.params)
    case .paneInfo: return await h.paneInfo(request.params)
    case .paneRead: return await h.paneRead(request.params)
    default: return nil
    }
  }

  private func routeHierarchy(_ request: IPC.Request) async -> RouterOutcome? {
    guard let h = hierarchyHandlers else { return nil }
    if let outcome = await routeHierarchyReads(request, handlers: h) { return outcome }
    if let outcome = await routeHierarchyMutations(request, handlers: h) { return outcome }
    if let outcome = await routeHierarchyTags(request, handlers: h) { return outcome }
    return nil
  }

  private func routeHierarchyReads(
    _ request: IPC.Request,
    handlers h: HierarchyHandlers
  ) async -> RouterOutcome? {
    switch request.method {
    case .hierarchyListProjects: return await h.listProjects(request.params)
    case .hierarchyListWorktrees: return await h.listWorktrees(request.params)
    case .hierarchyListTabs: return await h.listTabs(request.params)
    case .hierarchyListPanes: return await h.listPanes(request.params)
    case .hierarchyListTags: return await h.listTags(request.params)
    case .hierarchyResolveAlias: return await h.resolveAlias(request.params)
    default: return nil
    }
  }

  private func routeHierarchyMutations(
    _ request: IPC.Request,
    handlers h: HierarchyHandlers
  ) async -> RouterOutcome? {
    switch request.method {
    case .hierarchyAddProject: return await h.addProject(request.params)
    case .hierarchyRemoveProject: return await h.removeProject(request.params)
    case .hierarchyActivateWorktree: return await h.activateWorktree(request.params)
    case .hierarchyActivateTab: return await h.activateTab(request.params)
    case .hierarchyCreateWorktree: return await h.createWorktree(request.params)
    case .hierarchyRemoveWorktree: return await h.removeWorktree(request.params)
    case .hierarchyCreateTab: return await h.createTab(request.params)
    case .hierarchyCloseTab: return await h.closeTab(request.params)
    case .hierarchyOpenPane: return await h.openPane(request.params)
    case .hierarchyClosePane: return await h.closePane(request.params)
    case .hierarchyFocusPane: return await h.focusPane(request.params)
    case .hierarchySetPaneLabels: return await h.setPaneLabels(request.params)
    default: return nil
    }
  }

  /// Tag-scoped mutations. Lives in its own sub-router so the switch in
  /// `routeHierarchyMutations` doesn't grow unbounded.
  private func routeHierarchyTags(
    _ request: IPC.Request,
    handlers h: HierarchyHandlers
  ) async -> RouterOutcome? {
    switch request.method {
    case .hierarchyCreateTag: return await h.createTag(request.params)
    case .hierarchyRenameTag: return await h.renameTag(request.params)
    case .hierarchyRecolorTag: return await h.recolorTag(request.params)
    case .hierarchyRemoveTag: return await h.removeTag(request.params)
    case .hierarchySetProjectTags: return await h.setProjectTags(request.params)
    case .hierarchySetActiveTagFilter: return await h.setActiveTagFilter(request.params)
    default: return nil
    }
  }

  /// `editor.*` adapter. `EditorHandlers` exposes typed methods so tests
  /// can invoke them directly with `EditorOpenRequest` etc.; the router
  /// decodes `request.params`, invokes the matching method, and re-encodes
  /// the typed response.
  private func routeEditor(_ request: IPC.Request) async -> RouterOutcome? {
    guard let h = editorHandlers else { return nil }
    switch request.method {
    case .editorDescribe:
      let response = await h.describe()
      return Self.encodeUnary(response)
    case .editorOpen:
      do {
        let params = try request.params.decoded(as: EditorOpenRequest.self)
        let response = try await h.open(params)
        return Self.encodeUnary(response)
      } catch let error as EditorIPCError {
        return .failed(Self.mapEditorIPCError(error))
      } catch let error as DecodingError {
        return .failed(.invalidParams(message: String(describing: error), path: nil))
      } catch {
        return .failed(.internal(String(describing: error)))
      }
    case .editorSetGlobalDefault:
      do {
        let params = try request.params.decoded(as: EditorSetGlobalDefaultRequest.self)
        let response = h.setGlobalDefault(params)
        return Self.encodeUnary(response)
      } catch let error as DecodingError {
        return .failed(.invalidParams(message: String(describing: error), path: nil))
      } catch {
        return .failed(.internal(String(describing: error)))
      }
    case .editorSetProjectDefault:
      do {
        let params = try request.params.decoded(as: EditorSetProjectDefaultRequest.self)
        let response = try h.setProjectDefault(params)
        return Self.encodeUnary(response)
      } catch let error as EditorIPCError {
        return .failed(Self.mapEditorIPCError(error))
      } catch let error as DecodingError {
        return .failed(.invalidParams(message: String(describing: error), path: nil))
      } catch {
        return .failed(.internal(String(describing: error)))
      }
    default: return nil
    }
  }

  /// Encodes a typed response into a `RouterOutcome.unary(JSONValue)`. Encode
  /// failure is programmer error (DTOs are always Codable) — surface as
  /// `.internal` rather than crashing the connection.
  private static func encodeUnary<T: Encodable>(_ value: T) -> RouterOutcome {
    do {
      return .unary(try JSONValue.encoded(value))
    } catch {
      return .failed(.internal("encode failed: \(error)"))
    }
  }

  /// Maps an `EditorIPCError` to an `IPCError`. `unknownProject` carries caller-facing
  /// semantics → `notFound`. `notADirectory` is a caller input error → `invalidParams`.
  /// Launch / not-installed failures → `.unsupported(reason:)` so the CLI's existing
  /// `unsupported` exit code (4) surfaces them.
  private static func mapEditorIPCError(_ error: EditorIPCError) -> IPCError {
    switch error {
    case .unknownProject:
      return .notFound(kind: "project", id: "")
    case .notADirectory:
      return .invalidParams(
        message: "\(error.rawValue): \(error.shortMessage)",
        path: ["path"]
      )
    case .notInstalled, .launchFailed:
      return .unsupported(reason: "\(error.rawValue): \(error.shortMessage)")
    }
  }

  private func routeTerminal(_ request: IPC.Request) async -> RouterOutcome? {
    guard let t = terminalHandlers else { return nil }
    switch request.method {
    case .terminalSendInput: return await t.sendInput(request.params)
    case .terminalSendKey: return await t.sendKey(request.params)
    case .terminalSendRawBytes: return await t.sendRawBytes(request.params)
    case .terminalBroadcastInput: return await t.broadcastInput(request.params)
    case .terminalReadText: return await t.readText(request.params)
    case .terminalResetPane: return await t.resetPane(request.params)
    default: return nil
    }
  }

  private func routeSystem(_ request: IPC.Request) async -> RouterOutcome? {
    switch request.method {
    case .systemHello: return await systemHandlers.hello(request.params)
    case .systemPing: return await systemHandlers.ping(request.params)
    case .systemVersion: return await systemHandlers.version(request.params)
    case .systemStatus: return await systemHandlers.status(request.params)
    case .systemQuit: return await systemHandlers.quit(request.params)
    // Non-system methods fall through to the next sub-router. A future
    // `system.*` case landing in this router would silently reach
    // `notWired(.unsupported)` without this branch.
    default: return nil
    }
  }

  private func notWired(_ method: IPC.Method) -> RouterOutcome {
    .failed(.unsupported(reason: "method \(method.rawValue) not wired in this build"))
  }
}
