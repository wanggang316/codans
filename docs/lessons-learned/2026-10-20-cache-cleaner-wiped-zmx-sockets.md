# Lessons Learned: a cache cleaner wiped the zmx sockets and every reopened pane got a fresh shell

**Status:** Resolved
**Date:** 2026-10-20
**Area:** Pane runtime / persistence roots (`AppDirectories`, `PaneDaemonBringup`, `ZmxControlClient`, `SessionReaper`)
**Fix:** branch `fix/recycle` — `fix(runtime): keep zmx sockets out of the cache directory`

## Summary

Panes "lost" their session: a pane that had a Codex conversation running
showed a brand-new login shell the next time its worktree was opened. The
app had not been relaunched, nothing had crashed, and the pane kept its id.
The old daemon, and the Codex process under it, were still running.

## Root cause

The zmx `ZMX_DIR` — the directory the per-pane daemons bind their control
sockets in — was `~/Library/Caches/codans`. A cache cleaner (Mole, in this
case; CleanMyMac and a manual "clear caches" behave the same) deleted that
directory as a whole. Deleting a bound AF_UNIX socket file does not stop the
daemon; it only removes the one name the daemon can be reached by. The next
`zmx attach <paneID>` found no socket, so it did what it is designed to do
for a dead daemon: it created a new session with a new shell. The daemon
that held the user's work kept running, unreachable, forever.

Nothing in the app could have noticed. The reaper probes sockets by path at
launch, and bring-up attaches by path; a daemon with no path is invisible
to both. On the affected machine 130-odd orphaned `zmx attach` daemons from
previous cleans were still alive, each holding a shell and sometimes an
agent, none reachable.

## Evidence

- The cleaner's log named the deletion: `clean DELETED ~/Library/Caches/codans`
  at 18:48 local, and the same on an earlier day.
- `stat -f '%SB'` showed the cache directory itself born at 18:49 and every
  surviving socket born after it; `~/Library/Caches` siblings were born in
  the same minutes.
- `ps` listed two daemons for the same pane id: one from 15:39 (the lost
  session, still sleeping in `poll` with its listener bound to an unlinked
  inode) and one from 20:30 (the fresh shell).
- The pane's zmx log showed no kill, no exit, no cleanup between the client
  disconnect and the new `daemon started` line: the daemon never acted; its
  name was taken away.

## Fix

- The runtime root is now `~/.codans[-dev]/run` (`AppDirectories.runtimeDirectory`).
  It holds the sockets, the quit-time snapshots and zmx's own logs. It sits
  under the channel root, which nothing treats as disposable; the cache
  directory keeps only refetchable data.
- `CODANS_RUNTIME_DIR` relocates it. When only `CODANS_CACHE_DIR` is set the
  runtime root is `<cache>/run`, so the existing isolation harnesses keep
  private daemons without a change.
- On launch, `SessionReaper.migrateLegacySocketDirectory` renames the sockets
  of daemons that survived in the old directory into the new one and
  rewrites their `sessions.json` rows. A bound AF_UNIX socket stays
  connectable after `rename(2)` (the kernel matches the vnode, not the
  path), so an upgrade does not respawn a single pane. A legacy socket whose
  pane already has one in the runtime directory is an older duplicate and is
  killed.

## Recurrence checks

- Never put a Unix socket, a PID file or anything that is the only handle
  to a live process under `~/Library/Caches`, `$TMPDIR` or any directory a
  user or a tool is entitled to empty. The test
  `AppDirectoriesRuntimeDirectoryTests.runtimeRootIsNotUnderTheCacheRoot`
  pins this for the runtime root.
- "Session recycled with no relaunch" — first compare `ps -axo lstart,command | grep 'zmx attach <paneID>'`
  against the socket directory listing. Two daemons for one pane id, or a
  daemon with no socket file, means the name was lost, not the process.
- Orphans from before the fix cannot be adopted (no path to rename). They
  have to be killed by hand; the agent's own resume (`codex resume`,
  `claude --resume`) recovers the conversation, not the shell.
