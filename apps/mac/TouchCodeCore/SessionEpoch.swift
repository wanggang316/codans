import Darwin
import Foundation

/// Identity of the login (audit) session a `zmx` daemon was spawned into.
///
/// zmx daemons `setsid()`-detach and reparent to launchd so they survive
/// app quit (pane resume). That same detachment lets a daemon outlive the
/// *login session* it was born in: after a logout/login, fast-user-switch,
/// sleep/wake, or a relaunch into an incomplete session, the daemon keeps
/// running but the security/audit session it referenced is gone. Every
/// process under it then can no longer reach the per-session
/// opendirectoryd / keychain XPC, so `getpwuid(getuid())` fails — which
/// breaks ssh (`No user exists for uid <n>`), the login keychain, and `gh`
/// for the agent running in that pane. A pane opened fresh spawns a new
/// daemon in the live session and works, which is also why "restart the
/// app" never heals a stranded pane: relaunch re-attaches to the same
/// surviving daemon by its stable PaneID.
///
/// We stamp each persisted `Session` with the audit session id (asid) at
/// spawn time. On the next launch the reaper compares the row's stamp to
/// the live session's asid; a mismatch means the daemon belongs to a dead
/// session and is recycled (killed + pruned) so bring-up respawns it clean
/// in the live session.
public enum SessionEpoch {
  /// The live login session's audit session id as a string, or `nil` when
  /// this process's own session vantage point is untrustworthy:
  ///   - `getpwuid(getuid()) == nil` — directory services unreachable, i.e.
  ///     *we* are the stranded process; any comparison we make would be
  ///     garbage, so callers must skip epoch logic entirely rather than
  ///     mass-recycle healthy daemons from a broken vantage.
  ///   - `getaudit_addr` fails or reports no real session (`asid <= 0`,
  ///     i.e. `AU_DEFAUDITSID` / `AU_ASSIGN_ASID`).
  ///
  /// Never returns the sentinel as a real value, so a `nil` stamp always
  /// means "unknown", never "session zero".
  public static func current() -> String? {
    guard getpwuid(getuid()) != nil else { return nil }
    var info = auditinfo_addr_t()
    guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0 else {
      return nil
    }
    let asid = info.ai_asid
    guard asid > 0 else { return nil }
    return String(asid)
  }

  /// Pure decision used by the reaper: a daemon is stranded when we can
  /// trust our own vantage (`currentEpoch != nil`), the row carries a
  /// stamp (`rowEpoch != nil` — rows written by builds before this field
  /// existed stay `nil` and are left to the stale-cutoff path so an
  /// upgrade never mass-recycles existing panes), and the two disagree.
  public static func isStranded(rowEpoch: String?, currentEpoch: String?) -> Bool {
    guard let currentEpoch, let rowEpoch else { return false }
    return rowEpoch != currentEpoch
  }
}
