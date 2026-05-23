import Darwin
import Foundation
import TouchCodeCore
import os.log

/// Per-pane outcome of a `SessionReaper.sweep`. `.alive` entries name a
/// daemon whose Unix control socket responded to `connect(2)` within the
/// probe timeout; `.dead` entries are catalog rows whose socket is gone
/// or rejected our probe, and are removed from `sessions.json` as part
/// of the same sweep.
public enum SessionState: Sendable, Equatable {
  case alive(Session)
  case dead(Session)
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

  private let sessionStore: SessionStore
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.session.reaper")

  public init(sessionStore: SessionStore) {
    self.sessionStore = sessionStore
  }

  /// Read the on-disk catalog, probe every entry, and return per-paneID
  /// state. Dead entries are removed from the catalog and their socket
  /// files unlinked; the pruned catalog is persisted synchronously so a
  /// crash between the sweep and the first reattach does not resurrect
  /// stale rows.
  ///
  /// Throws only on a fatal read error. Decode failures are surfaced
  /// through `SessionStore.load` as an empty catalog (with the corrupt
  /// file moved aside), so the typical "no usable catalog" path returns
  /// an empty map without throwing.
  public func sweep() throws -> [PaneID: SessionState] {
    var catalog = try sessionStore.load()
    if catalog.sessions.isEmpty {
      return [:]
    }

    var states: [PaneID: SessionState] = [:]
    var deadKeys: [String] = []
    for (key, session) in catalog.sessions {
      let alive = Self.probe(socketPath: session.socketPath)
      if alive {
        states[session.paneID] = .alive(session)
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
        try sessionStore.saveNow(catalog)
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

    return states
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
}
