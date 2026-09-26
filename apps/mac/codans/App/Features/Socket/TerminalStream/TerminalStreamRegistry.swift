import CodansCore
import CodansIPC
import Foundation
import os

/// Opens `pane.attachStream` sessions and bounds how many run at once.
///
/// Every stream holds a daemon connection and up to `queueLimit` bytes of
/// undelivered output, so a caller gets at most `perCallerLimit` streams
/// and the Mac at most `totalLimit`; past either the answer is
/// `overloaded`. A slot is released when its session ends, which happens
/// when the pane exits or the connection carrying the stream goes away.
@MainActor
final class TerminalStreamRegistry {
  struct Dependencies {
    /// Whether the catalog knows the pane.
    var paneExists: @MainActor (PaneID) -> Bool
    /// The pane's zmx daemon control socket.
    var socketPath: @MainActor (PaneID) -> String
    /// The pane's grid on the Mac, when it has a live surface. Only a
    /// history-mode stream (old daemon) needs it.
    var gridSize: @MainActor (PaneID) -> PaneStreamSession.GridSize?
    /// Calls the handler whenever the pane's grid changes; returns a
    /// function that stops observing. Nil when the pane has no surface.
    var observeGeometry: @MainActor (PaneID, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?
    /// Opens an observer connection to a daemon socket.
    var connect: @MainActor (String) throws -> any ZmxObserverConnection = { path in
      try ZmxStreamClient(socketPath: path)
    }
    var clock: any Clock<Duration> = ContinuousClock()
  }

  static let perCallerLimit = 4
  static let totalLimit = 16

  private let dependencies: Dependencies
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "terminal-stream")
  private var active: [UUID: Entry] = [:]

  private struct Entry {
    let caller: String
    let stopObservingGeometry: (@MainActor () -> Void)?
  }

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  var activeCount: Int { active.count }

  func activeCount(for caller: String) -> Int {
    active.values.count { $0.caller == caller }
  }

  /// Opens a stream for `caller`, a key that groups one client's streams
  /// (see `CallerContext.streamCallerKey`).
  func attach(_ request: IPC.PaneAttachStreamRequest, caller: String) -> Result<PaneStreamSession, IPCError> {
    let paneID = request.paneID
    guard dependencies.paneExists(paneID) else {
      return .failure(.notFound(kind: "pane", id: paneID.description))
    }
    guard active.count < Self.totalLimit, activeCount(for: caller) < Self.perCallerLimit else {
      return .failure(.overloaded)
    }
    let path = dependencies.socketPath(paneID)
    let connection: any ZmxObserverConnection
    do {
      guard FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
      connection = try dependencies.connect(path)
    } catch {
      logger.info("pane \(paneID.description, privacy: .public) has no daemon to observe: \(String(describing: error), privacy: .public)")
      return .failure(.unsupported(reason: "pane has no running session"))
    }

    let sessionID = UUID()
    let session = PaneStreamSession(
      connection: connection,
      configuration: .clamped(scrollbackRows: request.scrollbackRows, coalesceMillis: request.coalesceMillis),
      clock: dependencies.clock,
      gridSize: { [weak self] in await self?.gridSize(paneID) },
      onEnd: { [weak self] in
        Task { @MainActor [weak self] in self?.release(sessionID) }
      }
    )
    let stopObserving = dependencies.observeGeometry(paneID) {
      Task { await session.geometryChanged() }
    }
    active[sessionID] = Entry(caller: caller, stopObservingGeometry: stopObserving)
    logger.info("stream opened for pane \(paneID.description, privacy: .public) (\(self.active.count, privacy: .public) active)")
    return .success(session)
  }

  private func gridSize(_ paneID: PaneID) -> PaneStreamSession.GridSize? {
    dependencies.gridSize(paneID)
  }

  private func release(_ sessionID: UUID) {
    guard let entry = active.removeValue(forKey: sessionID) else { return }
    entry.stopObservingGeometry?()
    logger.info("stream closed (\(self.active.count, privacy: .public) active)")
  }
}

extension CallerContext {
  /// Groups the streams one client holds, for `TerminalStreamRegistry`'s
  /// per-caller limit: a paired device by its ID, a local process by PID.
  var streamCallerKey: String {
    switch self {
    case .remote(let deviceID, _): return "remote:\(deviceID.uuidString)"
    case .local(let pid): return "local:\(pid.map(String.init) ?? "unknown")"
    }
  }
}
