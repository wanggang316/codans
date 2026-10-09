# Sourced by the user-test harnesses (bash 3.2 compatible).
#
# kill_zmx_sessions <cache dir>
#
# zmx session daemons outlive the app that started them, by design: the
# next launch reattaches. A test instance's daemons therefore survive its
# quit, and once the cache dir holding their sockets is deleted nothing can
# reach them any more. Kill every daemon whose socket lives in the dir, then
# check none is left. Only daemons of that dir are touched, never the ones
# of the release or dev app.
_zmx_pids_in() {
  local p
  for p in $(pgrep -f "zmx "); do
    lsof -a -p "$p" -U -F n 2>/dev/null | grep -qF "n$1/" && echo "$p"
  done
}

kill_zmx_sessions() {
  local dir="${1%/}" pids left _
  [[ -n "$dir" && "$dir" != / ]] || return 1
  pids=$(_zmx_pids_in "$dir")
  [[ -n "$pids" ]] || return 0
  kill -TERM $pids 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    left=""
    for p in $pids; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
    [[ -z "$left" ]] && break
    sleep 0.3
  done
  [[ -n "$left" ]] && kill -KILL $left 2>/dev/null
  left=$(_zmx_pids_in "$dir")
  if [[ -n "$left" ]]; then
    echo "WARNING: zmx session daemon(s) still hold sockets in $dir:" $left >&2
    return 1
  fi
}
