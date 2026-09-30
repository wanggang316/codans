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
    /// Opens a terminal seat (a participant client) at a daemon socket.
    var connectSeat: @MainActor (String, IPC.TerminalGridSize) throws -> any ZmxSeatConnection = { path, size in
      try ZmxParticipantClient(socketPath: path, cols: UInt16(size.cols), rows: UInt16(size.rows))
    }
    /// Whether nobody is at the Mac for this pane — it is not open there,
    /// the screen is locked, or the Mac has been idle for a while — so a
    /// seat asking to claim `.auto` takes the pane's size at once.
    var isMacAway: @MainActor (PaneID) -> Bool = { _ in false }
    var clock: any Clock<Duration> = ContinuousClock()
  }

  static let perCallerLimit = 4
  static let totalLimit = 16

  private let dependencies: Dependencies
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "terminal-stream")
  private var active: [UUID: Entry] = [:]

  private struct Entry {
    let caller: String
    let paneID: PaneID
    let stopObservingGeometry: (@MainActor () -> Void)?
    /// The caller's terminal seat, when it may type and sent its grid.
    let seat: (any ZmxSeatConnection)?
    let openedAt: UInt64
  }

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  var activeCount: Int { active.count }

  func activeCount(for caller: String) -> Int {
    active.values.count { $0.caller == caller }
  }

  /// Opens a stream for `caller`, a key that groups one client's streams
  /// (see `CallerContext.streamCallerKey`). A caller that `canType` and
  /// sends its grid also gets a terminal seat at the pane's session.
  func attach(
    _ request: IPC.PaneAttachStreamRequest, caller: String, canType: Bool = false
  ) -> Result<PaneStreamSession, IPCError> {
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
    let seat = canType ? openSeat(request, path: path) : nil
    active[sessionID] = Entry(
      caller: caller, paneID: paneID, stopObservingGeometry: stopObserving, seat: seat,
      openedAt: DispatchTime.now().uptimeNanoseconds)
    logger.info("stream opened for pane \(paneID.description, privacy: .public) (\(self.active.count, privacy: .public) active)")
    return .success(session)
  }

  private func gridSize(_ paneID: PaneID) -> PaneStreamSession.GridSize? {
    dependencies.gridSize(paneID)
  }

  private func release(_ sessionID: UUID) {
    guard let entry = active.removeValue(forKey: sessionID) else { return }
    entry.stopObservingGeometry?()
    // The daemon hands the lead, and the pane's size, back to the Mac.
    entry.seat?.close()
    logger.info("stream closed (\(self.active.count, privacy: .public) active)")
  }

  // MARK: - Seats

  private func openSeat(_ request: IPC.PaneAttachStreamRequest, path: String) -> (any ZmxSeatConnection)? {
    guard let size = request.seat, size.isValid else { return nil }
    let seat: any ZmxSeatConnection
    do {
      seat = try dependencies.connectSeat(path, size)
    } catch {
      logger.info(
        "no seat for pane \(request.paneID.description, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return nil
    }
    logger.info(
      "seat opened for pane \(request.paneID.description, privacy: .public) at \(size.cols, privacy: .public)x\(size.rows, privacy: .public), claim \((request.claim ?? .never).rawValue, privacy: .public)"
    )
    switch request.claim ?? .never {
    case .now:
      seat.claim()
    case .auto where dependencies.isMacAway(request.paneID):
      seat.claim()
    case .auto, .never:
      break
    }
    return seat
  }

  /// The caller's seat at the pane: its newest stream's, when several.
  private func seat(caller: String, paneID: PaneID) -> (any ZmxSeatConnection)? {
    active.values
      .filter { $0.caller == caller && $0.paneID == paneID && $0.seat != nil }
      .max { $0.openedAt < $1.openedAt }?
      .seat
  }

  func setSeatSize(_ request: IPC.PaneSetStreamSizeRequest, caller: String) -> Result<Void, IPCError> {
    guard request.size.isValid else {
      return .failure(.invalidParams(message: "size out of range", path: ["size"]))
    }
    guard let seat = seat(caller: caller, paneID: request.paneID) else { return .failure(Self.noSeat) }
    seat.setSize(cols: UInt16(request.size.cols), rows: UInt16(request.size.rows))
    return .success(())
  }

  func claimSize(_ request: IPC.PaneClaimSizeRequest, caller: String) -> Result<Void, IPCError> {
    guard let seat = seat(caller: caller, paneID: request.paneID) else { return .failure(Self.noSeat) }
    if request.claim { seat.claim() } else { seat.release() }
    return .success(())
  }

  func input(_ request: IPC.PaneInputRequest, caller: String) -> Result<Void, IPCError> {
    guard let bytes = request.bytes, bytes.count <= IPC.PaneInputRequest.maxBytes else {
      return .failure(.invalidParams(message: "data must be base64, at most 64 KiB", path: ["data"]))
    }
    guard let seat = seat(caller: caller, paneID: request.paneID) else { return .failure(Self.noSeat) }
    seat.sendInput(bytes)
    return .success(())
  }

  static let noSeat = IPCError.unsupported(reason: "no terminal seat for this pane; attach a stream with a seat first")
}

/// The seat side of a zmx daemon connection, as `TerminalStreamRegistry`
/// drives it. `ZmxParticipantClient` is the real one; tests substitute a
/// fake.
nonisolated protocol ZmxSeatConnection: AnyObject, Sendable {
  func setSize(cols: UInt16, rows: UInt16)
  func sendInput(_ bytes: Data)
  func claim()
  func release()
  func close()
}

extension ZmxParticipantClient: ZmxSeatConnection {}

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
