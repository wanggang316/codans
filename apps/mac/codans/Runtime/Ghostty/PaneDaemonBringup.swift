import Foundation
import CodansCore

/// Canonical filesystem locations shared by the zmx-backed pane runtime.
///
/// Pane I/O runs `zmx attach <session>` under libghostty's exec backend
/// (see `ZmxAttachCommand` and `TerminalEngine.ensureSurface`), so there is
/// no in-app daemon spawn/handshake anymore. What remains here is the small
/// set of locations every part of that path agrees on: the embedded `zmx`
/// binary, the daemon socket directory (`ZMX_DIR`), and the snapshot
/// directory the reaper scans.
@MainActor
enum PaneDaemonBringup {
  /// Canonical zmx `ZMX_DIR`. The daemon places its control socket here
  /// and writes snapshots into `<ZMX_DIR>/snapshots/<paneID>.snap`. We
  /// pin this to `~/Library/Caches/<AppDirectories.name>` (`codans`, or
  /// `codans-dev` for Debug builds) so the socket path the daemon binds
  /// lines up byte-for-byte with `ZmxControlClient.socketPath` and
  /// `SessionReaper`'s launch-time scan — without a pin, zmx falls back to
  /// `$TMPDIR/zmx-<uid>` (or `$XDG_RUNTIME_DIR/zmx`) which would scatter
  /// sockets somewhere the reaper has no reason to look. The Debug suffix
  /// keeps a locally-built dev instance's daemons isolated from the
  /// installed Release's, which is what prevents pane-session crosstalk
  /// when both run at once (see `AppDirectories`).
  static func canonicalSocketDirectory() -> URL {
    AppDirectories.cacheDirectory()
  }

  /// Directory the daemon writes `<paneID>.snap` into when `.Snapshot`
  /// fires. Kept here (rather than re-derived in `SessionReaper`) so the
  /// canonical path has one owner.
  static func canonicalSnapshotDirectory() -> URL {
    canonicalSocketDirectory().appendingPathComponent("snapshots", isDirectory: true)
  }

  /// Resolves the bundled `zmx` binary out of the app bundle's
  /// `Resources/bin/` folder. Tuist's `Embed zmx` build phase
  /// (apps/mac/scripts/embed-zmx.sh) is responsible for putting it
  /// there; absent the resource we cannot proceed.
  static func zmxBinaryURL() throws -> URL {
    guard
      let url = Bundle.main.url(
        forResource: "zmx", withExtension: nil, subdirectory: "bin"
      )
    else {
      throw HierarchyError.zmxBinaryMissing
    }
    return url
  }
}
