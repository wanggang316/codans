#!/usr/bin/env bash
# Helpers for the self-verify skill. Source this file from the
# repository root in bash or zsh. Sourcing defines functions only; it does
# not launch anything.
#
# Every instance resource is private: config dir, terminal cache dir (zmx
# sockets), and RPC socket. Gump's release and dev apps are never addressed
# by name, by default socket, or by default directory.

# The process that outlives every shell of this session: the nearest
# ancestor that is not a shell or a command wrapper. For an agent it is the
# agent process (each Bash call of Claude Code or Codex is a child shell of
# it); for a person it is the terminal's login process. Prints
# "<pid> <start time>" so a reused PID is not the same session. Prints
# nothing when only launchd is left (a reparented daemon).
sv_session_anchor() {
  local pid=$$ name
  while [ "${pid:-1}" -gt 1 ]; do
    name="$(ps -o comm= -p "$pid" 2>/dev/null)"
    name="${name##*/}"
    case "${name#-}" in
      "") return 0 ;;
      sh | bash | zsh | dash | ksh | fish | env | nohup | timeout | gtimeout | sandbox-exec | xargs | make | gmake)
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        ;;
      *)
        printf '%s %s\n' "$pid" "$(ps -o lstart= -p "$pid" | tr -s ' ')"
        return 0
        ;;
    esac
  done
}

# The session id that scopes the default paths: SELF_VERIFY_SESSION, else
# the Claude Code session, else the session's anchor process. Terminal and
# pane ids (TERM_SESSION_ID, CODANS_PANE_ID) are not used: every agent that
# an engine starts from one pane inherits them.
sv_session_id() {
  local id="${SELF_VERIFY_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$id" ] || id="anchor $(sv_session_anchor)"
  printf '%s\n' "$id"
}

# Short token for <worktree root> and <session id>. Pure: no environment.
sv_session_token() {
  printf '%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-8
}

# Parallel sessions on one machine must not share an instance: a shared
# socket refuses the second launch, and a shared dir lets one session's
# sv_cleanup delete the other's config and pid file. So the defaults are
# scoped to the worktree and the session.
sv_token="$(sv_session_token "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" "$(sv_session_id)")"
SELF_VERIFY_DIR="${SELF_VERIFY_DIR:-${TMPDIR%/}/codans-self-verify-$(id -u)-$sv_token}"
# AF_UNIX paths are capped at 104 bytes. The RPC socket and the cache dir
# (which holds one zmx socket per pane, named by a 36-char pane UUID) stay
# short and outside SELF_VERIFY_DIR.
SELF_VERIFY_SOCKET="${SELF_VERIFY_SOCKET:-/tmp/cdv-sv-$(id -u)-$sv_token.sock}"
SELF_VERIFY_CACHE="${SELF_VERIFY_CACHE:-/tmp/cdv-sv-cache-$(id -u)-$sv_token}"
unset sv_token
SELF_VERIFY_DEFAULTS_DOMAIN="${SELF_VERIFY_DEFAULTS_DOMAIN:-com.gumpw.codans}"

sv_conf_dir() { printf '%s\n' "$SELF_VERIFY_DIR/conf"; }
sv_pid_file() { printf '%s\n' "$SELF_VERIFY_DIR/app.pid"; }

# Resolve the Debug Codans.app built from this worktree. Cache the answer:
# `xcodebuild -showBuildSettings` takes several seconds. An explicit
# SELF_VERIFY_DIR can be shared by worktrees, so the cache holds the worktree
# root on line 1 and the app on line 2, and only that worktree reuses it.
sv_app() {
  if [ -n "${SELF_VERIFY_APP:-}" ]; then
    printf '%s\n' "$SELF_VERIFY_APP"
    return
  fi
  local cache="$SELF_VERIFY_DIR/app-path" root app
  root="$(git rev-parse --show-toplevel)" || return 1
  if [ -s "$cache" ] && [ "$(sed -n 1p "$cache")" = "$root" ]; then
    app="$(sed -n 2p "$cache")"
    if [ -n "$app" ] && [ -d "$app" ]; then
      printf '%s\n' "$app"
      return
    fi
  fi
  app="$(cd "$root/apps/mac" && xcodebuild -workspace codans.xcworkspace -scheme Codans \
    -configuration Debug -showBuildSettings 2>/dev/null |
    awk '$1=="BUILT_PRODUCTS_DIR"{d=$3} $1=="FULL_PRODUCT_NAME"{p=$3} END{print d "/" p}')"
  [ -d "$app" ] || {
    printf 'self-verify: Debug app not found at %s (run make mac-build)\n' "$app" >&2
    return 1
  }
  mkdir -p "$SELF_VERIFY_DIR"
  printf '%s\n%s\n' "$root" "$app" >"$cache"
  printf '%s\n' "$app"
}

sv_executable() { printf '%s\n' "$(sv_app)/Contents/MacOS/Codans"; }

# Refuse paths that would reach a real app or break zmx. Pure: no I/O.
# Usage: sv_validate_paths <socket> <cache dir>
sv_validate_paths() {
  local socket="$1" cache="$2" uid
  uid="$(id -u)"
  case "$socket" in
    "/tmp/codans-$uid.sock" | "/tmp/codans-dev-$uid.sock")
      printf 'self-verify: %s is a channel default socket\n' "$socket" >&2
      return 1
      ;;
  esac
  case "$cache" in
    "$HOME/Library/Caches/codans" | "$HOME/Library/Caches/codans-dev" | "$HOME/Library/Caches/codans/"* | "$HOME/Library/Caches/codans-dev/"*)
      printf 'self-verify: %s is a channel default cache dir\n' "$cache" >&2
      return 1
      ;;
  esac
  if [ "${#socket}" -gt 100 ]; then
    printf 'self-verify: socket path is %s bytes; keep it under 100\n' "${#socket}" >&2
    return 1
  fi
  # <cache>/<36-char pane UUID> must fit in 104 bytes.
  if [ "${#cache}" -gt 60 ]; then
    printf 'self-verify: cache path is %s bytes; keep it under 60\n' "${#cache}" >&2
    return 1
  fi
}

# Run a command with the calling pane's codans context removed and the
# private instance paths set. Used for the app and the CLI alike. With
# CODANS_STATE_DIR unset, the state root follows CODANS_CONFIG_DIR.
sv_env() {
  env -u CODANS_PANE_ID -u CODANS_CLI -u CODANS_WORKTREE_PATH -u CODANS_ROOT_PATH \
    -u CODANS_WORKSPACE_ROOT -u CODANS_PROJECT_ID -u CODANS_WORKTREE_ID -u CODANS_TAB_ID \
    -u CODANS_TAG_ID -u CODANS_HANDOFF_REQUEST_ID -u ZMX_DIR -u ZMX_SESSION \
    -u TERM_PROGRAM -u TERM_PROGRAM_VERSION -u CODANS_STATE_DIR -u CODANS_RUNTIME_DIR \
    CODANS_SOCKET_PATH="$SELF_VERIFY_SOCKET" \
    CODANS_CONFIG_DIR="$(sv_conf_dir)" \
    CODANS_CACHE_DIR="$SELF_VERIFY_CACHE" \
    "$@"
}

# The CLI bundled in the Debug app (`codans-dev`), pinned to the private socket.
codans_debug() {
  local cli
  cli="${SELF_VERIFY_CLI:-$(sv_app)/Contents/Resources/bin/codans-dev}" || return 1
  sv_env "$cli" "$@"
}

# Seed a scratch settings.json that keeps worktrees and fetches out of the
# user's data. Pass extra JSON through SELF_VERIFY_SETTINGS to replace it.
sv_seed_settings() {
  local conf
  conf="$(sv_conf_dir)"
  mkdir -p "$conf" "$SELF_VERIFY_DIR/worktrees"
  if [ -n "${SELF_VERIFY_SETTINGS:-}" ]; then
    printf '%s\n' "$SELF_VERIFY_SETTINGS" >"$conf/settings.json"
  else
    # No update checks or crash reports from a test instance.
    cat >"$conf/settings.json" <<EOF
{
  "version": 3,
  "general": { "updatesAutomaticallyCheckForUpdates": false, "crashReportsEnabled": false },
  "worktree": { "defaultWorktreesDirectory": "$SELF_VERIFY_DIR/worktrees", "fetchRemoteOnCreate": false }
}
EOF
  fi
}

# Restore the shared multi-branch fixture repo. Prints its path.
sv_fixture_repo() {
  local root dest="${1:-$SELF_VERIFY_DIR/fixture}"
  root="$(git rev-parse --show-toplevel)" || return 1
  rm -rf "$dest"
  bash "$root/.claude/skills/self-verify/fixtures/restore-repo.sh" "$dest" >/dev/null || return 1
  printf '%s\n' "$dest"
}

# True when <path> is this run's Debug executable. Pure string check.
sv_is_instance_executable() {
  [ -n "$1" ] && [ "$1" = "$2" ]
}

# The instance PID, only when the recorded PID is still our executable.
# Identity is the pid file plus the executable path, never the process name:
# release, dev, and test instances are all called "Codans".
sv_pid() {
  local file pid exe
  file="$(sv_pid_file)"
  [ -s "$file" ] || return 1
  pid="$(cat "$file")"
  exe="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')"
  sv_is_instance_executable "$exe" "$(sv_executable)" || return 1
  printf '%s\n' "$pid"
}

sv_defaults_snapshot() {
  defaults export "$SELF_VERIFY_DEFAULTS_DOMAIN" "$SELF_VERIFY_DIR/defaults-before.plist" 2>/dev/null ||
    printf '{}' | plutil -convert xml1 -o "$SELF_VERIFY_DIR/defaults-before.plist" -
}

# Put back every key of the shared UserDefaults domain that changed since
# sv_defaults_snapshot (window frames, split positions, Sparkle flags). The
# release and dev apps write the same domain, so only changed keys are
# touched; a whole-domain import would drop their writes. Values go back as
# XML plist fragments, which keeps arrays, dictionaries, and numbers typed.
sv_defaults_restore() {
  local before="$SELF_VERIFY_DIR/defaults-before.plist" after="$SELF_VERIFY_DIR/defaults-after.plist"
  [ -f "$before" ] || return 0
  defaults export "$SELF_VERIFY_DEFAULTS_DOMAIN" "$after" 2>/dev/null || return 0
  python3 - "$before" "$after" <<'PY' | while IFS="$(printf '\t')" read -r op key value; do
import plistlib, re, sys
with open(sys.argv[1], "rb") as f: before = plistlib.load(f)
with open(sys.argv[2], "rb") as f: after = plistlib.load(f)
for key in sorted(set(before) | set(after)):
    if before.get(key) == after.get(key):
        continue
    if key not in before:
        print(f"delete\t{key}\t")
        continue
    xml = plistlib.dumps(before[key], fmt=plistlib.FMT_XML).decode()
    fragment = re.search(r"<plist[^>]*>(.*)</plist>", xml, re.S).group(1)
    print(f"write\t{key}\t{' '.join(fragment.split())}")
PY
    case "$op" in
      write) defaults write "$SELF_VERIFY_DEFAULTS_DOMAIN" "$key" "$value" && printf 'defaults restored: %s\n' "$key" ;;
      delete) defaults delete "$SELF_VERIFY_DEFAULTS_DOMAIN" "$key" && printf 'defaults removed: %s\n' "$key" ;;
    esac
  done
}

# Launch the isolated instance and wait until its socket answers.
# Refuses when the socket is held by anything else.
sv_launch() {
  local exe pid up front
  sv_validate_paths "$SELF_VERIFY_SOCKET" "$SELF_VERIFY_CACHE" || return 1
  exe="$(sv_executable)" || return 1
  [ -x "$exe" ] || {
    printf 'self-verify: %s is missing\n' "$exe" >&2
    return 1
  }
  if pid="$(sv_pid)"; then
    printf 'self-verify: instance already running (pid %s)\n' "$pid" >&2
    return 1
  fi
  if [ -S "$SELF_VERIFY_SOCKET" ]; then
    if lsof -t "$SELF_VERIFY_SOCKET" >/dev/null 2>&1; then
      printf 'self-verify: %s is held by another process (set SELF_VERIFY_SESSION to a unique id)\n' \
        "$SELF_VERIFY_SOCKET" >&2
      return 1
    fi
    rm -f "$SELF_VERIFY_SOCKET"
  fi
  mkdir -p "$SELF_VERIFY_DIR" "$SELF_VERIFY_CACHE"
  [ -f "$(sv_conf_dir)/settings.json" ] || sv_seed_settings
  sv_defaults_snapshot
  front="$(sv_tool front 2>/dev/null)"
  rm -f "$(sv_pid_file)"
  sv_env nohup "$exe" >"$SELF_VERIFY_DIR/app.log" 2>&1 &
  # `$!` can name a wrapper subshell, so take the PID from the process that
  # binds the private socket and check its executable path.
  sv_wait_ready || return 1
  pid="$(sv_pid)" || return 1
  # A socket answered by an older instance would make every check lie.
  up="$(codans_debug status --json | jq -r '.data.uptimeSeconds')"
  awk -v u="$up" 'BEGIN { exit !(u + 0 <= 30) }' || {
    printf 'self-verify: socket answered with uptime %s s; refusing\n' "$up" >&2
    return 1
  }
  lsof -a -p "$pid" -U 2>/dev/null | grep -q "$SELF_VERIFY_SOCKET" || {
    printf 'self-verify: pid %s does not hold %s\n' "$pid" "$SELF_VERIFY_SOCKET" >&2
    return 1
  }
  # Launched from the frontmost app's terminal, the instance can inherit
  # activation. Give focus back to the user's app.
  if [ -n "$front" ] && [ "$(sv_tool front 2>/dev/null)" = "$pid" ]; then
    sv_tool activate "$front" >/dev/null 2>&1
  fi
  printf 'self-verify: instance pid %s on %s\n' "$pid" "$SELF_VERIFY_SOCKET"
}

sv_wait_ready() {
  local attempt holder exe
  exe="$(sv_executable)" || return 1
  for attempt in $(seq 1 100); do
    if [ ! -s "$(sv_pid_file)" ] && [ -S "$SELF_VERIFY_SOCKET" ]; then
      for holder in $(lsof -t "$SELF_VERIFY_SOCKET" 2>/dev/null); do
        if sv_is_instance_executable "$(ps -p "$holder" -o comm= | sed 's/^[[:space:]]*//')" "$exe"; then
          printf '%s\n' "$holder" >"$(sv_pid_file)"
        fi
      done
    fi
    if sv_pid >/dev/null &&
      codans_debug doctor --json 2>/dev/null | jq -e '.data.socketStatus == "ok"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  printf 'self-verify: socket did not answer within 20 s\n' >&2
  return 1
}

# Compile sv-tool.swift once per scratch dir (rebuilt when the source is newer).
sv_tool() {
  local root src tool="$SELF_VERIFY_DIR/sv-tool"
  root="$(git rev-parse --show-toplevel)" || return 1
  src="$root/.claude/skills/self-verify/scripts/sv-tool.swift"
  mkdir -p "$SELF_VERIFY_DIR"
  if [ ! -x "$tool" ] || [ "$src" -nt "$tool" ]; then
    swiftc -O "$src" -o "$tool" >/dev/null || return 1
  fi
  "$tool" "$@"
}

# List the instance's on-screen windows: "<id> <x> <y> <w> <h> <title>".
sv_windows() {
  local pid
  pid="$(sv_pid)" || return 1
  sv_tool windows "$pid" "$@"
}

# First on-screen window id of the instance, optionally matched by title.
sv_window_id() { sv_windows "$@" | awk 'NR==1 {print $1}'; }

# Capture one instance window without raising it or touching other apps.
# Usage: sv_screenshot <out.png> [title substring]
sv_screenshot() {
  local out="$1" wid
  shift
  wid="$(sv_window_id "$@")"
  [ -n "$wid" ] || {
    printf 'self-verify: no on-screen window for the instance\n' >&2
    return 1
  }
  screencapture -o -x -l"$wid" "$out"
}

# Semantic AX commands by PID (see the header of sv-tool.swift). None of them
# activates the instance or moves the cursor, so they are safe while the user
# works in other apps. Elements are addressed by AX role plus exact label.
sv_ax() {
  local pid command="$1"
  shift
  pid="$(sv_pid)" || return 1
  sv_tool "$command" "$pid" "$@"
}

# Indented AX tree with roles, labels, #identifiers, {actions}, and frames:
# sv_tree [--window <title>] [--depth N]
sv_tree() { sv_ax tree "$@"; }
# Elements by role (or "any") and exact label: sv_find AXButton Run [--within L]
sv_find() { sv_ax find "$@"; }
# One element as JSON: value, enabled, selected, focused, frame, actions.
sv_get() { sv_ax get "$@"; }
# Wait until an element appears, or with --gone disappears; exit 2 on timeout.
sv_wait() { sv_ax wait "$@"; }
# AXPress one element: sv_press AXMenuItem Always. Refuses an element without
# an AXPress action, because AX reports success for those and nothing happens.
sv_press() { sv_ax press "$@"; }
# Focus a text field and set its value: sv_set_value AXTextField "Filter branches" main
sv_set_value() { sv_ax set-value "$@"; }
# Select an outline or table row by its text (Settings sidebar).
sv_select_row() { sv_ax select-row "$@"; }
# Press a menu-bar item by title path: sv_menu Codans "Settings…"
sv_menu() { sv_ax menu "$@"; }
# Make a window main (no activation); a new window can take over the main role.
sv_main_window() { sv_ax main-window "$@"; }
sv_close_window() { sv_ax close-window "$@"; }
sv_cancel_menu() { sv_ax cancel-menu; }
# Center "<x> <y>" of an element frame, for sv_click and sv_hover.
sv_center() { sv_ax center "$@"; }

# Physical input: use only when no semantic (AX) action exists. Every event
# is guarded: the instance is activated by PID and the event is refused unless
# the instance owns the topmost window under the point. Wrap a multi-step
# sequence (hover, then click a revealed control) in sv_physical_begin /
# sv_physical_end so focus and cursor go back to the user once.
sv_physical_begin() {
  sv_tool front >"$SELF_VERIFY_DIR/physical-front"
  sv_tool cursor >"$SELF_VERIFY_DIR/physical-cursor"
}

sv_physical_end() {
  local front cursor
  front="$(cat "$SELF_VERIFY_DIR/physical-front" 2>/dev/null)"
  cursor="$(cat "$SELF_VERIFY_DIR/physical-cursor" 2>/dev/null)"
  [ -n "$cursor" ] && sv_tool warp "${cursor% *}" "${cursor#* }"
  [ -n "$front" ] && [ "$front" -gt 0 ] && [ "$front" != "$(sv_pid)" ] && sv_tool activate "$front"
  rm -f "$SELF_VERIFY_DIR/physical-front" "$SELF_VERIFY_DIR/physical-cursor"
}

# Guarded click at global (x, y). Outside a begin/end block, focus and cursor
# are given back right after the click.
sv_click() {
  local pid
  pid="$(sv_pid)" || return 1
  if [ -f "$SELF_VERIFY_DIR/physical-front" ]; then
    sv_tool click "$pid" "$1" "$2" --stay
  else
    sv_tool click "$pid" "$1" "$2"
  fi
}

# Guarded hover at global (x, y). Leaves the instance active and the cursor
# in place, so call it inside sv_physical_begin / sv_physical_end.
sv_hover() {
  local pid
  pid="$(sv_pid)" || return 1
  [ -f "$SELF_VERIFY_DIR/physical-front" ] || {
    printf 'self-verify: call sv_physical_begin before sv_hover\n' >&2
    return 1
  }
  sv_tool hover "$pid" "$1" "$2"
}

# Crash bracket for one UI step: sv_crash_mark, the step, sv_crash_check.
# A complete AX walk does not prove the absence of a crash: the app can
# crash a moment later (lessons-learned 2026-11-09). The check fails when
# the instance is gone or ReportCrash wrote a new Codans-*.ips for the
# instance PID. Release, dev, and test instances all write Codans-*.ips, so a
# report counts only when its PID is the marked instance.
sv_crash_dir() { printf '%s\n' "${SELF_VERIFY_CRASH_DIR:-$HOME/Library/Logs/DiagnosticReports}"; }
sv_crash_mark_file() { printf '%s\n' "$SELF_VERIFY_DIR/crash-mark"; }

sv_crash_reports() {
  find "$(sv_crash_dir)" -maxdepth 1 -name 'Codans-*.ips' 2>/dev/null | sort
}

# Record the instance PID (line 1) and the reports that exist now.
sv_crash_mark() {
  local pid
  pid="$(sv_pid)" || {
    printf 'self-verify: no running instance to mark\n' >&2
    return 1
  }
  { printf '%s\n' "$pid"; sv_crash_reports; } >"$(sv_crash_mark_file)"
}

# Print each report written since the mark for <pid>: its path, the
# exception, and the top frames of the crashed thread.
# The script comes on stdin, so the report paths go in a file.
sv_crash_new_reports() {
  local list="$SELF_VERIFY_DIR/crash-reports"
  sv_crash_reports >"$list"
  python3 - "$(sv_crash_mark_file)" "$list" "$1" "${SELF_VERIFY_CRASH_FRAMES:-15}" <<'PY'
import json, sys
mark, listing, pid, limit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(mark) as f:
    known = set(f.read().splitlines()[1:])
with open(listing) as f:
    paths = f.read().splitlines()
for path in paths:
    if path in known:
        continue
    try:
        with open(path) as f:
            body = json.loads(f.read().split("\n", 1)[1])
    except (OSError, ValueError, IndexError):
        continue  # Not a crash report, or still being written.
    if body.get("pid") != pid:
        continue
    exc = body.get("exception", {})
    print(f"crash report: {path}")
    print(f"  {exc.get('type', '?')} ({exc.get('signal', '?')}) {exc.get('subtype', '')}".rstrip())
    images = body.get("usedImages", [])
    threads = body.get("threads", [])
    crashed = next((t for t in threads if t.get("triggered")), None)
    if crashed is None:
        index = body.get("faultingThread")
        crashed = threads[index] if isinstance(index, int) and index < len(threads) else {}
    for i, frame in enumerate(crashed.get("frames", [])[:limit]):
        index = frame.get("imageIndex")
        image = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
        if "symbol" in frame:
            where = f"{frame['symbol']} + {frame.get('symbolLocation', 0)}"
        else:
            where = hex(frame.get("imageOffset", 0))
        print(f"  {i:>3} {image:<24} {where}")
PY
}

# Wait SELF_VERIFY_CRASH_SETTLE seconds (default 3), then fail when the
# marked instance is gone or a new report names its PID. A dead instance gets
# up to SELF_VERIFY_CRASH_WAIT more seconds (default 15) for ReportCrash to
# write the report.
sv_crash_check() {
  local mark pid reports gone=0 attempt
  mark="$(sv_crash_mark_file)"
  [ -s "$mark" ] || {
    printf 'self-verify: call sv_crash_mark before sv_crash_check\n' >&2
    return 1
  }
  pid="$(sed -n 1p "$mark")"
  sleep "${SELF_VERIFY_CRASH_SETTLE:-3}"
  [ "$(sv_pid 2>/dev/null)" = "$pid" ] || gone=1
  reports="$(sv_crash_new_reports "$pid")"
  if [ "$gone" = 1 ] && [ -z "$reports" ]; then
    for attempt in $(seq 1 "$(awk -v w="${SELF_VERIFY_CRASH_WAIT:-15}" 'BEGIN { print int(w * 2) }')"); do
      sleep 0.5
      reports="$(sv_crash_new_reports "$pid")"
      [ -z "$reports" ] || break
    done
  fi
  if [ "$gone" = 0 ] && [ -z "$reports" ]; then
    printf 'self-verify: crash check passed: pid %s is alive, no new crash report\n' "$pid"
    return 0
  fi
  if [ "$gone" = 1 ]; then
    printf 'self-verify: crash check FAILED: instance pid %s is gone\n' "$pid" >&2
  else
    printf 'self-verify: crash check FAILED: instance pid %s wrote a crash report\n' "$pid" >&2
  fi
  if [ -n "$reports" ]; then
    printf '%s\n' "$reports" >&2
  else
    printf 'self-verify: no new Codans-*.ips report for pid %s in %s\n' "$pid" "$(sv_crash_dir)" >&2
  fi
  return 1
}

# PIDs that hold files under the private cache dir (zmx daemons and their
# attach clients). Scoped by path so Gump's dev daemons are never matched.
sv_cache_pids() {
  [ -d "$SELF_VERIFY_CACHE" ] || return 0
  lsof -t +D "$SELF_VERIFY_CACHE" 2>/dev/null | sort -u
}

# Close every pane of the private instance, stop it, kill leftover daemons,
# restore shared defaults, and remove the private paths.
sv_cleanup() {
  local pid pane alive attempt
  if pid="$(sv_pid)"; then
    for pane in $(codans_debug tree --json 2>/dev/null | jq -r '.data.projects[]?.worktrees[]?.tabs[]?.panes[]?.id'); do
      codans_debug pane close "$pane" >/dev/null 2>&1
    done
    kill -TERM "$pid" 2>/dev/null
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      sv_pid >/dev/null || break
      sleep 0.5
    done
    sv_pid >/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
  for pid in $(sv_cache_pids); do
    [ "$pid" = "$$" ] || kill -TERM "$pid" 2>/dev/null
  done
  sleep 0.5
  alive="$(sv_cache_pids | tr '\n' ' ')"
  [ -z "${alive// /}" ] || printf 'self-verify: still alive under cache: %s\n' "$alive" >&2
  sv_defaults_restore
  rm -f "$SELF_VERIFY_SOCKET" "$(sv_pid_file)"
  rm -rf "$SELF_VERIFY_CACHE"
  if [ "${SELF_VERIFY_KEEP_DIR:-0}" != 1 ]; then
    rm -rf "$SELF_VERIFY_DIR"
  fi
  printf 'self-verify: cleanup done\n'
}
