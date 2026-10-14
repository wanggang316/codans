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
    /// Whether nobody can see the pane on the Mac — it is not open in a
    /// visible window — so a seat asking to claim `.auto` takes the pane's
    /// size at once. Where the pane is on screen, resizing it for a device
    /// would disturb what the Mac shows; the device waits until its user
    /// types.
    var isHiddenOnMac: @MainActor (PaneID) -> Bool = { _ in false }
    /// The paired device's name for a caller key, for the Mac's notice.
    var deviceName: @MainActor (String) -> String? = { _ in nil }
    var clock: any Clock<Duration> = ContinuousClock()
  }

  static let perCallerLimit = 4
  static let totalLimit = 16

  private let dependencies: Dependencies
  /// Panes sized for a device, for the Mac's panes to show.
  let sizing: RemotePaneSizing
  private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "terminal-stream")
  private var active: [UUID: Entry] = [:]
  /// Each observed pane's PTY grid, as its daemon last reported it.
  private var ptyGrids: [PaneID: PaneStreamSession.GridSize] = [:]

  private struct Entry {
    let caller: String
    let paneID: PaneID
    let stopObservingGeometry: (@MainActor () -> Void)?
    /// The caller's terminal seat, when it may type and sent its grid.
    let seat: (any ZmxSeatConnection)?
    /// The grid the seat asks for.
    var seatSize: IPC.TerminalGridSize?
    let openedAt: UInt64
  }

  init(dependencies: Dependencies, sizing: RemotePaneSizing = RemotePaneSizing()) {
    self.dependencies = dependencies
    self.sizing = sizing
    sizing.takeBack = { [weak self] paneID in self?.giveSizeBack(paneID) }
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
      onGrid: { [weak self] grid in
        Task { @MainActor [weak self] in self?.ptyGridChanged(paneID, to: grid) }
      },
      onEnd: { [weak self] in
        Task { @MainActor [weak self] in self?.release(sessionID) }
      }
    )
    let stopObserving = dependencies.observeGeometry(paneID) { [weak self] in
      Task { await session.geometryChanged() }
      self?.refreshSizing(paneID)
    }
    let seat = canType ? openSeat(request, path: path) : nil
    active[sessionID] = Entry(
      caller: caller, paneID: paneID, stopObservingGeometry: stopObserving, seat: seat,
      seatSize: seat == nil ? nil : request.seat,
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
    if !active.values.contains(where: { $0.paneID == entry.paneID }) { ptyGrids[entry.paneID] = nil }
    refreshSizing(entry.paneID)
    logger.info("stream closed (\(self.active.count, privacy: .public) active)")
  }

  // MARK: - Sizing

  private func ptyGridChanged(_ paneID: PaneID, to grid: PaneStreamSession.GridSize) {
    guard active.values.contains(where: { $0.paneID == paneID }) else { return }
    ptyGrids[paneID] = grid
    refreshSizing(paneID)
  }

  /// Records whether a device has the pane at its size: the PTY is at a
  /// seat's grid and not at the Mac's. Matching a seat's grid keeps a
  /// moment of the Mac's own resizing (a split drag, say) from reading as
  /// a device's.
  private func refreshSizing(_ paneID: PaneID) {
    let atSeatGrid: (Entry, PaneStreamSession.GridSize) -> Bool = { entry, pty in
      entry.paneID == paneID && entry.seatSize.map { Int(pty.cols) == $0.cols && Int(pty.rows) == $0.rows } == true
    }
    guard let pty = ptyGrids[paneID], let mac = dependencies.gridSize(paneID), pty != mac,
      let leader = active.values.filter({ atSeatGrid($0, pty) }).max(by: { $0.openedAt < $1.openedAt })
    else {
      sizing.set(nil, for: paneID)
      return
    }
    sizing.set(
      RemotePaneSizing.Sizing(
        deviceName: dependencies.deviceName(leader.caller), cols: Int(pty.cols), rows: Int(pty.rows),
        macCols: Int(mac.cols), macRows: Int(mac.rows)),
      for: paneID)
  }

  /// The Mac asked for the pane's size back: every seat at it lets go of
  /// the lead, which the daemon hands to its most recently active client.
  func giveSizeBack(_ paneID: PaneID) {
    for entry in active.values where entry.paneID == paneID { entry.seat?.release() }
    logger.info("size given back to the Mac for pane \(paneID.description, privacy: .public)")
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
    case .auto where dependencies.isHiddenOnMac(request.paneID):
      seat.claim()
    case .auto, .never:
      break
    }
    return seat
  }

  /// The caller's seat at the pane: its newest stream's, when several.
  private func seat(caller: String, paneID: PaneID) -> (any ZmxSeatConnection)? {
    seatEntryID(caller: caller, paneID: paneID).flatMap { active[$0]?.seat }
  }

  private func seatEntryID(caller: String, paneID: PaneID) -> UUID? {
    active
      .filter { $0.value.caller == caller && $0.value.paneID == paneID && $0.value.seat != nil }
      .max { $0.value.openedAt < $1.value.openedAt }?
      .key
  }

  func setSeatSize(_ request: IPC.PaneSetStreamSizeRequest, caller: String) -> Result<Void, IPCError> {
    guard request.size.isValid else {
      return .failure(.invalidParams(message: "size out of range", path: ["size"]))
    }
    guard let id = seatEntryID(caller: caller, paneID: request.paneID), let seat = active[id]?.seat else {
      return .failure(Self.noSeat)
    }
    active[id]?.seatSize = request.size
    seat.setSize(cols: UInt16(request.size.cols), rows: UInt16(request.size.rows))
    refreshSizing(request.paneID)
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

  /// The paired device behind a `streamCallerKey`, if it names one.
  static func deviceID(fromStreamCallerKey key: String) -> UUID? {
    guard key.hasPrefix("remote:") else { return nil }
    return UUID(uuidString: String(key.dropFirst("remote:".count)))
  }
}
