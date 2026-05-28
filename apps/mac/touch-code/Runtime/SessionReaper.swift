import Darwin
import Foundation
import TouchCodeCore
import os.log

/// Per-pane outcome of a `SessionReaper.sweep`. `.alive` entries name a
/// daemon whose Unix control socket responded to `connect(2)` within the
/// probe timeout; `.dead` entries are catalog rows whose socket is gone
/// or rejected our probe, and are removed from `sessions.json` as part
/// of the same sweep. `.snapshot` entries name a paneID for which a
/// `<paneID>.snap` file exists in the canonical snapshot directory but
/// no live daemon was found — set by M3.T3.2's quit-time snapshot tier
/// when the "Resume panes on launch" toggle is off.
public enum SessionState: Sendable, Equatable {
  case alive(Session)
  case dead(Session)
  case snapshot(URL)
}

/// Launch-time companion to `SessionLifecycle`. Reads the persisted
/// `sessions.json` catalog, probes each entry's daemon socket, and
/// returns a per-paneID state map so the pane-creation path can divert
/// to `PaneDaemonBringup.reattach` for daemons that survived the last
/// quit (M2.T2). Dead entries are pruned from the on-disk catalog and
/// their stale socket files unlinked best-effort so a future sweep
/// starts from a clean slate.
///
/// Force-quit (`kill -9 TouchCode`) needs no special handling: zmx
/// daemons run with `posix.setsid()` and survive the app's process
/// group teardown (verified at T0.3), so the same `connect` probe
/// identifies them as alive.
@MainActor
public final class SessionReaper {
  /// Maximum time the probe will wait for `connect(2)` to complete.
  /// Generous for a local Unix socket — the daemon either accepts the
  /// connection immediately or `ECONNREFUSED`s. A few hundred
  /// milliseconds covers contended boots without dragging launch.
  private static let probeTimeoutMS: Int32 = 200

  private let coordinator: SessionCoordinator
  private let snapshotDirectory: URL
  private let staleAfter: TimeInterval
  private let clock: @MainActor () -> Date
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.session.reaper")

  public init(
    coordinator: SessionCoordinator,
    snapshotDirectory: URL? = nil,
    staleAfter: TimeInterval = SessionConfig.defaultStaleAfter,
    clock: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.coordinator = coordinator
    self.snapshotDirectory = snapshotDirectory ?? PaneDaemonBringup.canonicalSnapshotDirectory()
    self.staleAfter = staleAfter
    self.clock = clock
  }

  /// Read the on-disk catalog, probe every entry, and return per-paneID
  /// state. Dead entries are removed from the catalog and their socket
  /// files unlinked; the pruned catalog is persisted synchronously so a
  /// crash between the sweep and the first reattach does not resurrect
  /// stale rows.
  ///
  /// `livePaneIDs`, when supplied, enables the orphan branch: a daemon
  /// whose socket answers `connect(2)` but whose `PaneID` is absent
  /// from the hierarchy catalog has no surface to reattach to. The
  /// `ensureSurface` path would never claim it, so without this branch
  /// the daemon would survive untouched until the 7-day stale cutoff
  /// caught it. Such orphans are killed immediately and pruned in the
  /// same persist pass as `.dead` rows. Callers that cannot supply the
  /// hierarchy (e.g. unit tests) pass `nil` to retain the
  /// liveness-only semantics.
  ///
  /// Throws only on a fatal read error. Decode failures are surfaced
  /// through `SessionStore.load` as an empty catalog (with the corrupt
  /// file moved aside), so the typical "no usable catalog" path returns
  /// an empty map without throwing.
  public func sweep(livePaneIDs: Set<PaneID>? = nil) throws -> [PaneID: SessionState] {
    var catalog = coordinator.catalog

    let now = clock()
    let staleCutoff = now.addingTimeInterval(-staleAfter)

    var states: [PaneID: SessionState] = [:]
    var deadKeys: [String] = []
    for (key, session) in catalog.sessions {
      let alive = Self.probe(socketPath: session.socketPath)
      if alive {
        if session.lastAttachedAt < staleCutoff {
          // Stale daemon: send `.kill` over a one-shot connection, then
          // treat the entry as dead so the row is pruned and the
          // snapshot file (if any) cleaned up alongside it. We don't
          // wait for the daemon to fully exit — `.kill` is best-effort
          // and the next sweep would re-probe and clean up anyway.
          logger.notice(
            "Killing stale daemon for pane \(session.paneID, privacy: .public): lastAttachedAt=\(session.lastAttachedAt, privacy: .public) older than staleAfter=\(self.staleAfter)s"
          )
          Self.sendOneShotKill(socketPath: session.socketPath)
          states[session.paneID] = .dead(session)
          deadKeys.append(key)
          _ = Darwin.unlink(session.socketPath)
          deleteSnapshotFile(for: session.paneID)
        } else if let livePaneIDs, !livePaneIDs.contains(session.paneID) {
          // Orphan daemon: alive on the wire, but no surface in the
          // hierarchy will ever claim it. Mirror the stale branch —
          // one-shot kill, prune the row, drop the socket and any
          // companion snapshot — so resources don't leak across launches
          // when sessions.json and hierarchy.json fall out of sync.
          logger.notice(
            "Killing orphan daemon for pane \(session.paneID, privacy: .public) (not present in hierarchy)"
          )
          Self.sendOneShotKill(socketPath: session.socketPath)
          states[session.paneID] = .dead(session)
          deadKeys.append(key)
          _ = Darwin.unlink(session.socketPath)
          deleteSnapshotFile(for: session.paneID)
        } else {
          states[session.paneID] = .alive(session)
        }
      } else {
        states[session.paneID] = .dead(session)
        deadKeys.append(key)
        // Best-effort unlink — the daemon may have exited and left a
        // stale socket file behind (zmx normally cleans up, but a
        // SIGKILL'd daemon will not). Ignore ENOENT and any other
        // failure: the catalog row is the source of truth and is being
        // removed regardless.
        _ = Darwin.unlink(session.socketPath)
      }
    }

    if !deadKeys.isEmpty {
      for key in deadKeys {
        catalog.sessions.removeValue(forKey: key)
      }
      do {
        try coordinator.replace(catalog)
      } catch {
        // Failing to persist the pruned catalog is non-fatal: the
        // states map is still correct for this launch, and the next
        // sweep will re-probe and re-prune. Log loudly so a chronic
        // failure (disk full, sandbox revoke) shows up in Console.
        logger.error(
          "Failed to persist pruned sessions.json: \(String(describing: error), privacy: .public)"
        )
      }
    }

    // M3.T3.3 snapshot fallback: every `<paneID>.snap` file in the
    // canonical snapshot directory becomes a `.snapshot` state unless
    // the paneID already has a live daemon (in which case the snap is
    // stale and is unlinked). Snapshots and live daemons co-existing
    // for the same paneID would have meant the toggle was flipped from
    // off → on between two quits without a relaunch in between; the
    // live daemon wins, and the snap is dropped.
    mergeSnapshotsIntoStates(&states)

    return states
  }

  /// Scan `snapshotDirectory` for `<uuid>.snap` files and merge them
  /// into the per-paneID state map. Stale snapshots whose paneID is
  /// already `.alive` are deleted from disk so a future sweep does not
  /// re-discover them. Missing-directory and any other I/O failure are
  /// non-fatal: we simply produce no extra entries.
  private func mergeSnapshotsIntoStates(_ states: inout [PaneID: SessionState]) {
    let fm = FileManager.default
    let dirPath = snapshotDirectory.path
    guard fm.fileExists(atPath: dirPath) else { return }
    let contents: [URL]
    do {
      contents = try fm.contentsOfDirectory(
        at: snapshotDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    } catch {
      logger.error(
        "Failed to scan snapshot directory \(dirPath, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return
    }

    for url in contents where url.pathExtension == "snap" {
      let stem = url.deletingPathExtension().lastPathComponent
      guard let uuid = UUID(uuidString: stem) else { continue }
      let paneID = PaneID(raw: uuid)
      switch states[paneID] {
      case .alive:
        // Live daemon trumps a stale snapshot. The live tier on the next
        // quit will produce a fresh catalog row; the snap from the
        // previous snapshot-tier quit is no longer the source of truth.
        do {
          try fm.removeItem(at: url)
        } catch {
          logger.warning(
            "Failed to remove stale snapshot \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
          )
        }
      case .dead, .none:
        states[paneID] = .snapshot(url)
      case .snapshot:
        // Already set (shouldn't happen — uuid is unique within a scan)
        // but guard against duplicates rather than overwriting silently.
        continue
      }
    }
  }

  /// Synchronous `connect(2)` probe against a Unix domain socket. Uses
  /// `O_NONBLOCK` + `poll(2)` for a bounded wait so a half-open socket
  /// (daemon hung, kernel still routing) cannot stall launch indefinitely.
  /// Returns `true` only on a clean accept; any errno (ENOENT,
  /// ECONNREFUSED, timeout) is treated as "dead".
  private static func probe(socketPath: String) -> Bool {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { _ = Darwin.close(fd) }

    // Non-blocking so connect() can return EINPROGRESS and we control
    // the wait window via poll() rather than the kernel's default
    // connection timeout.
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 {
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      return false
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult == 0 {
      // Connected immediately. Local Unix sockets often take this path
      // when the daemon's accept queue is idle.
      return true
    }
    if errno != EINPROGRESS {
      // ENOENT, ECONNREFUSED, EACCES, etc. — daemon is gone.
      return false
    }

    // Wait for the socket to become writable (connect complete) or for
    // the probe deadline to elapse.
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let polled = withUnsafeMutablePointer(to: &pfd) {
      Darwin.poll($0, 1, probeTimeoutMS)
    }
    if polled <= 0 {
      // 0 = timeout, <0 = poll error. Either way, daemon is unreachable.
      return false
    }

    // Re-check SO_ERROR — POLLOUT can fire on a failed connect too, in
    // which case getsockopt reports the underlying errno.
    var soError: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    let rc = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
    return rc == 0 && soError == 0
  }

  /// Hand-rolled one-shot `.kill` IPC: open a Unix socket, write a
  /// framed `.kill` request, wait briefly for the socket to EOF
  /// (daemon exit) or for the 2 s deadline. We avoid spinning up a
  /// full `ZmxClient` for the stale path because the only signal we
  /// need is "daemon exit" — `ZmxClient` would also start a read
  /// loop, register a continuation, and keep `kill()` MainActor-
  /// bound, none of which fit a fire-and-forget reap.
  ///
  /// All failures (connect refused, write short, poll timeout) are
  /// silent: the caller has already decided to drop this row from
  /// the catalog and unlink the socket file. The next sweep would
  /// catch a daemon that somehow survived the kill.
  private static func sendOneShotKill(socketPath: String) {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return }
    defer { _ = Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
        pathBytes.withUnsafeBufferPointer { src in
          _ = memcpy(dst, src.baseAddress, pathBytes.count)
        }
      }
    }
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult != 0 { return }

    // Wire format mirrors `ZmxFraming.encode(ZmxFrame(tag: .kill))`:
    // `[tag(1)=5][len_LE(4)=0][padding(3)=0]`. Hand-rolled here to
    // keep the reaper's import graph minimal (no `TouchCodeIPC`
    // dependency) and because `.kill` has no payload — encode is
    // a constant 8-byte sequence.
    let killFrame: [UInt8] = [
      0x05,  // ZmxTag.kill = 5
      0x00, 0x00, 0x00, 0x00,  // little-endian u32 length = 0
      0x00, 0x00, 0x00,  // 3 zero padding bytes
    ]
    let written = killFrame.withUnsafeBytes { buf in
      Darwin.write(fd, buf.baseAddress, buf.count)
    }
    if written != killFrame.count { return }

    // Wait for the daemon to close the socket (POLLIN with zero-length
    // read = EOF) or for the 2 s budget to elapse. We don't try to
    // read any reply — `.kill` is one-way; the daemon's exit IS the
    // ack.
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    _ = withUnsafeMutablePointer(to: &pfd) {
      Darwin.poll($0, 1, 2000)
    }
  }

  /// Remove `<paneID>.snap` from the canonical snapshot directory.
  /// Used by the 7-day reap path so a stale daemon's last snapshot
  /// does not get picked up by the snapshot-tier merge as a "ghost"
  /// resumable pane. Missing-file and any other I/O failure is
  /// non-fatal — the merge already skips paneIDs whose UUID does
  /// not parse, and a stranded snap will eventually be reaped by
  /// the orphan-snap sweep in the bring-up path.
  private func deleteSnapshotFile(for paneID: PaneID) {
    let snapURL = snapshotDirectory.appendingPathComponent("\(paneID.raw.uuidString).snap")
    let fm = FileManager.default
    guard fm.fileExists(atPath: snapURL.path) else { return }
    do {
      try fm.removeItem(at: snapURL)
    } catch {
      logger.warning(
        "Failed to remove snapshot for stale pane \(paneID, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }
}
