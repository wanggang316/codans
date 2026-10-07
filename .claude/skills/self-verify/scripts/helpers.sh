#!/usr/bin/env bash
# Helpers for the self-verify skill. Source this file from the
# repository root in bash or zsh. Sourcing defines functions only; it does
# not launch anything.
#
# Every instance resource is private: config dir, terminal cache dir (zmx
# sockets), and RPC socket. Gump's release and dev apps are never addressed
# by name, by default socket, or by default directory.

SELF_VERIFY_DIR="${SELF_VERIFY_DIR:-${TMPDIR%/}/codans-self-verify-$(id -u)}"
# AF_UNIX paths are capped at 104 bytes. The RPC socket and the cache dir
# (which holds one zmx socket per pane, named by a 36-char pane UUID) stay
# short and outside SELF_VERIFY_DIR.
SELF_VERIFY_SOCKET="${SELF_VERIFY_SOCKET:-/tmp/cdv-sv-$(id -u).sock}"
SELF_VERIFY_CACHE="${SELF_VERIFY_CACHE:-/tmp/cdv-sv-cache-$(id -u)}"
SELF_VERIFY_DEFAULTS_DOMAIN="${SELF_VERIFY_DEFAULTS_DOMAIN:-com.gumpw.codans}"

sv_conf_dir() { printf '%s\n' "$SELF_VERIFY_DIR/conf"; }
sv_pid_file() { printf '%s\n' "$SELF_VERIFY_DIR/app.pid"; }

# Resolve the Debug Codans.app built from this worktree. Cache the answer:
# `xcodebuild -showBuildSettings` takes several seconds.
sv_app() {
  if [ -n "${SELF_VERIFY_APP:-}" ]; then
    printf '%s\n' "$SELF_VERIFY_APP"
    return
  fi
  local cache="$SELF_VERIFY_DIR/app-path" root app
  if [ -s "$cache" ] && [ -d "$(cat "$cache")" ]; then
    cat "$cache"
    return
  fi
  root="$(git rev-parse --show-toplevel)" || return 1
  app="$(cd "$root/apps/mac" && xcodebuild -workspace codans.xcworkspace -scheme Codans \
    -configuration Debug -showBuildSettings 2>/dev/null |
    awk '$1=="BUILT_PRODUCTS_DIR"{d=$3} $1=="FULL_PRODUCT_NAME"{p=$3} END{print d "/" p}')"
  [ -d "$app" ] || {
    printf 'self-verify: Debug app not found at %s (run make mac-build)\n' "$app" >&2
    return 1
  }
  mkdir -p "$SELF_VERIFY_DIR"
  printf '%s\n' "$app" >"$cache"
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
    -u TERM_PROGRAM -u TERM_PROGRAM_VERSION -u CODANS_STATE_DIR \
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
      printf 'self-verify: %s is held by another process\n' "$SELF_VERIFY_SOCKET" >&2
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
