#!/usr/bin/env bash
# Tests for helpers.sh. Runs a fake app (a C program that binds the private
# socket) and a fake CLI, so it needs no Debug build and never starts Codans.
#
# Usage: bash|zsh .claude/skills/self-verify/tests/helpers_test.sh

set -u

scripts_dir="$(cd "$(dirname "$0")/../scripts" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sv-helpers-test.XXXXXX")"
test_domain="com.gumpw.codans.self-verify-test.$$"
failures=0

cleanup() {
  [ -s "$scratch/sv/app.pid" ] && kill -KILL "$(cat "$scratch/sv/app.pid")" 2>/dev/null
  [ -n "${holder_pid:-}" ] && kill -KILL "$holder_pid" 2>/dev/null
  defaults delete "$test_domain" >/dev/null 2>&1
  for f in "$scratch"/session-*.env; do
    [ -f "$f" ] || continue
    (. "$f" && [ -s "$SELF_VERIFY_DIR/app.pid" ] && kill -KILL "$(cat "$SELF_VERIFY_DIR/app.pid")" 2>/dev/null
      rm -rf "$SELF_VERIFY_SOCKET" "$SELF_VERIFY_CACHE")
  done
  rm -rf "$scratch" "/tmp/cdv-t$$.sock" "/tmp/cdv-t$$-c"
}
trap cleanup EXIT

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
check() { # check <name> <command...>
  local name="$1"
  shift
  if "$@" >"$scratch/out" 2>&1; then pass "$name"; else
    fail "$name"
    sed 's/^/     /' "$scratch/out"
  fi
}
check_not() {
  local name="$1"
  shift
  if "$@" >"$scratch/out" 2>&1; then
    fail "$name"
    sed 's/^/     /' "$scratch/out"
  else pass "$name"; fi
}

# ---------- fake app and CLI ----------
mkdir -p "$scratch/Fake.app/Contents/MacOS" "$scratch/Fake.app/Contents/Resources/bin"
cat >"$scratch/fake-app.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
int main(void) {
  const char *path = getenv("CODANS_SOCKET_PATH");
  if (!path) return 2;
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {0};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) return 3;
  listen(fd, 1);
  for (;;) pause();
}
C
cc -o "$scratch/Fake.app/Contents/MacOS/Codans" "$scratch/fake-app.c" || exit 1
cp "$scratch/Fake.app/Contents/MacOS/Codans" "$scratch/socket-holder"
cat >"$scratch/Fake.app/Contents/Resources/bin/codans-dev" <<'SH'
#!/bin/sh
# Records the environment it sees, then answers like a healthy instance.
env >"$(dirname "$0")/last-env"
case "$1" in
  doctor) [ -S "$CODANS_SOCKET_PATH" ] && echo '{"ok":true,"data":{"socketStatus":"ok"}}' || echo '{"ok":true,"data":{"socketStatus":"socket-missing"}}' ;;
  status) echo "{\"ok\":true,\"data\":{\"uptimeSeconds\":${FAKE_UPTIME:-1}}}" ;;
  tree) echo '{"ok":true,"data":{"projects":[]}}' ;;
  *) exit 64 ;;
esac
SH
chmod +x "$scratch/Fake.app/Contents/Resources/bin/codans-dev"

export SELF_VERIFY_DIR="$scratch/sv"
export SELF_VERIFY_APP="$scratch/Fake.app"
export SELF_VERIFY_SOCKET="/tmp/cdv-t$$.sock"
export SELF_VERIFY_CACHE="/tmp/cdv-t$$-c"
export SELF_VERIFY_DEFAULTS_DOMAIN="$test_domain"
export SELF_VERIFY_KEEP_DIR=1
# shellcheck source=helpers.sh
. "$scripts_dir/helpers.sh"

# ---------- pure checks ----------
uid="$(id -u)"
check_not "rejects the release socket" sv_validate_paths "/tmp/codans-$uid.sock" /tmp/c
check_not "rejects the dev socket" sv_validate_paths "/tmp/codans-dev-$uid.sock" /tmp/c
check_not "rejects the dev cache dir" sv_validate_paths /tmp/s.sock "$HOME/Library/Caches/codans-dev"
check_not "rejects a long cache dir" sv_validate_paths /tmp/s.sock "/tmp/$(printf 'x%.0s' $(seq 1 60))"
check_not "rejects a long socket" sv_validate_paths "/tmp/$(printf 'x%.0s' $(seq 1 100)).sock" /tmp/c
check "accepts the default private paths" sv_validate_paths "$SELF_VERIFY_SOCKET" "$SELF_VERIFY_CACHE"
check "matches the exact executable" sv_is_instance_executable /a/Codans.app/Contents/MacOS/Codans /a/Codans.app/Contents/MacOS/Codans
check_not "rejects another Codans build" sv_is_instance_executable /Applications/Codans.app/Contents/MacOS/Codans /a/Codans.app/Contents/MacOS/Codans
check_not "rejects an empty executable" sv_is_instance_executable "" /a/Codans.app/Contents/MacOS/Codans

# ---------- app path resolution ----------
# Two worktrees share one SELF_VERIFY_DIR. A fake xcodebuild reports a build
# dir inside the worktree it runs in and counts its calls.
mkdir -p "$scratch/bin"
cat >"$scratch/bin/xcodebuild" <<'SH'
#!/bin/sh
echo x >>"$XCODEBUILD_CALLS"
printf '    BUILT_PRODUCTS_DIR = %s/build\n    FULL_PRODUCT_NAME = Codans.app\n' "$PWD"
SH
chmod +x "$scratch/bin/xcodebuild"
for wt in wt-a wt-b; do
  mkdir -p "$scratch/$wt/apps/mac/build/Codans.app"
  git -C "$scratch/$wt" init -q
done
wt_a="$(cd "$scratch/wt-a" && pwd -P)"
wt_b="$(cd "$scratch/wt-b" && pwd -P)"
export XCODEBUILD_CALLS="$scratch/xcodebuild-calls"
app_in() ( # app_in <worktree>: sv_app with default settings, run from <worktree>
  unset SELF_VERIFY_APP
  cd "$1" && PATH="$scratch/bin:$PATH" sv_app
)
calls() { wc -l <"$XCODEBUILD_CALLS" 2>/dev/null | tr -d ' ' || echo 0; }
check "resolves worktree A's app" test "$(app_in "$wt_a")" = "$wt_a/apps/mac/build/Codans.app"
calls_before="$(calls)"
check "reuses the cache in the same worktree" test "$(app_in "$wt_a")" = "$wt_a/apps/mac/build/Codans.app"
check "a cache hit skips xcodebuild" test "$(calls)" = "$calls_before"
check "worktree B ignores A's cached app" test "$(app_in "$wt_b")" = "$wt_b/apps/mac/build/Codans.app"
check "worktree A gets its own app again" test "$(app_in "$wt_a")" = "$wt_a/apps/mac/build/Codans.app"
check "explicit SELF_VERIFY_APP wins" test "$(cd "$wt_b" && SELF_VERIFY_APP=/x/Override.app sv_app)" = /x/Override.app

# ---------- environment scrubbing ----------
CODANS_PANE_ID=leak CODANS_SOCKET_PATH=/tmp/codans-$uid.sock ZMX_SESSION=leak TERM_PROGRAM=codans \
  CODANS_STATE_DIR="$HOME/.codans-dev/state" codans_debug tree --json >/dev/null
envfile="$scratch/Fake.app/Contents/Resources/bin/last-env"
check_not "CLI does not see CODANS_PANE_ID" grep -q '^CODANS_PANE_ID=' "$envfile"
check_not "CLI does not see ZMX_SESSION" grep -q '^ZMX_SESSION=' "$envfile"
check_not "CLI does not see TERM_PROGRAM" grep -q '^TERM_PROGRAM=' "$envfile"
# A caller's state root would win over CODANS_CONFIG_DIR and reach real data.
check_not "CLI does not see CODANS_STATE_DIR" grep -q '^CODANS_STATE_DIR=' "$envfile"
check "CLI gets the private socket" grep -qx "CODANS_SOCKET_PATH=$SELF_VERIFY_SOCKET" "$envfile"
check "CLI gets the private cache dir" grep -qx "CODANS_CACHE_DIR=$SELF_VERIFY_CACHE" "$envfile"
check "CLI gets the private config dir" grep -qx "CODANS_CONFIG_DIR=$SELF_VERIFY_DIR/conf" "$envfile"

# ---------- launch refusals ----------
CODANS_SOCKET_PATH="$SELF_VERIFY_SOCKET" "$scratch/socket-holder" &
holder_pid=$!
for i in $(seq 1 50); do
  [ -S "$SELF_VERIFY_SOCKET" ] && break
  sleep 0.1
done
check_not "refuses a socket held by another process" sv_launch
kill -KILL "$holder_pid" 2>/dev/null
wait "$holder_pid" 2>/dev/null
holder_pid=""
rm -f "$SELF_VERIFY_SOCKET"

# ---------- lifecycle ----------
defaults write "$test_domain" "NSWindow Frame main" -string "0 0 800 600"
defaults write "$test_domain" keepCount -int 1
defaults write "$test_domain" "NSSplitView Subview Frames main" -array "0, 0, 266, 1050" "0, 0, 192, 1050"
check "launches the fake instance" sv_launch
pid="$(sv_pid)"
check "sv_pid names the socket holder" test "$(lsof -t "$SELF_VERIFY_SOCKET" | head -1)" = "$pid"
check "seeds scratch settings" grep -q "$SELF_VERIFY_DIR/worktrees" "$SELF_VERIFY_DIR/conf/settings.json"
check_not "refuses a second launch" sv_launch
cp "$(sv_pid_file)" "$scratch/real-pid"
echo 1 >"$(sv_pid_file)"
check_not "sv_pid rejects a PID that is not the instance executable" sv_pid
cp "$scratch/real-pid" "$(sv_pid_file)"

# The instance moved its window and created a split-view key.
defaults write "$test_domain" "NSWindow Frame main" -string "10 10 1100 720"
defaults write "$test_domain" "NSSplitView Subview Frames x" -string "a"
defaults write "$test_domain" keepCount -int 2
defaults write "$test_domain" "NSSplitView Subview Frames main" -array "0, 0, 266, 1050" "0, 0, 124, 1050"
# A daemon that holds a file in the private cache dir must be stopped too.
(cd "$SELF_VERIFY_CACHE" && exec sleep 300) &
daemon_pid=$!
sleep 0.2

sv_cleanup >"$scratch/cleanup.out" 2>&1; check "cleanup succeeds" test $? -eq 0
check_not "instance process is gone" kill -0 "$pid"
check_not "cache-dir daemon is gone" kill -0 "$daemon_pid"
check_not "socket is removed" test -e "$SELF_VERIFY_SOCKET"
check_not "cache dir is removed" test -e "$SELF_VERIFY_CACHE"
check "window frame is restored" test "$(defaults read "$test_domain" "NSWindow Frame main")" = "0 0 800 600"
check_not "new split-view key is removed" defaults read "$test_domain" "NSSplitView Subview Frames x"
check "number is restored with its type" test "$(defaults read-type "$test_domain" keepCount) $(defaults read "$test_domain" keepCount)" = "Type is integer 1"
check "array is restored" test "$(defaults read "$test_domain" "NSSplitView Subview Frames main" | tr -d ' \n')" = '("0,0,266,1050","0,0,192,1050")'
check "array keeps its type" test "$(defaults read-type "$test_domain" "NSSplitView Subview Frames main")" = "Type is array"

# ---------- per-session defaults ----------
# Run a command with no session variable and no explicit path variable.
no_session_env() {
  env -u SELF_VERIFY_DIR -u SELF_VERIFY_SOCKET -u SELF_VERIFY_CACHE -u SELF_VERIFY_SESSION \
    -u CLAUDE_CODE_SESSION_ID -u SELF_VERIFY_KEEP_DIR TMPDIR="$scratch/tmp/" "$@"
}
print_paths='. "$1" && printf "SELF_VERIFY_DIR=%s\nSELF_VERIFY_SOCKET=%s\nSELF_VERIFY_CACHE=%s\n" "$SELF_VERIFY_DIR" "$SELF_VERIFY_SOCKET" "$SELF_VERIFY_CACHE"'
# Print the default paths a fresh shell gets in <dir> for session id <id>
# (empty: no session variable, so the anchor process decides).
session_paths() ( # session_paths <dir> <id> [extra env...]
  dir="$1" id="$2"
  shift 2
  cd "$dir" && no_session_env ${id:+SELF_VERIFY_SESSION="$id"} "$@" bash -c "$print_paths" _ "$scripts_dir/helpers.sh"
)
# A stand-in for an agent process: not a shell, and it runs each argument in
# its own fresh `bash -c`, one after another, as an agent runs Bash calls.
printf '%s\n' 'import subprocess, sys' 'for step in sys.argv[1:]:' '    subprocess.call(["bash", "-c", step])' \
  >"$scratch/anchor.py"
anchor() { no_session_env python3 "$scratch/anchor.py" "$@"; }
mkdir -p "$scratch/tmp"
session_paths "$wt_a" "a$$" >"$scratch/paths-a1"
session_paths "$wt_a" "a$$" >"$scratch/paths-a2"
session_paths "$wt_a" "b$$" >"$scratch/paths-b"
session_paths "$wt_b" "a$$" >"$scratch/paths-wt-b"
session_paths "$wt_a" "" CLAUDE_CODE_SESSION_ID="claude$$" >"$scratch/paths-claude"
session_paths "$wt_a" "" >"$scratch/paths-none"
# One agent, two shells: the second goes through env and nohup wrappers.
printf 'cd "$1" && shift && %s\n' "$print_paths" >"$scratch/print-paths.sh"
step="bash '$scratch/print-paths.sh' '$wt_a' '$scripts_dir/helpers.sh'"
anchor "$step" "env nohup $step" >"$scratch/paths-agent-x" 2>/dev/null
anchor "$step" >"$scratch/paths-agent-y"
sed -n 1,3p "$scratch/paths-agent-x" >"$scratch/paths-agent-x1"
sed -n 4,6p "$scratch/paths-agent-x" >"$scratch/paths-agent-x2"
no_shared_path() { # no_shared_path <file> <file>: no line is the same in both
  [ -s "$1" ] && [ -s "$2" ] && [ -z "$(sort "$1" "$2" | uniq -d)" ]
}
same_paths() { [ -s "$1" ] && cmp -s "$1" "$2"; }
check "a session gets the same paths in every shell" cmp -s "$scratch/paths-a1" "$scratch/paths-a2"
check "two sessions in one worktree share no path" no_shared_path "$scratch/paths-a1" "$scratch/paths-b"
check "one session id in two worktrees shares no path" no_shared_path "$scratch/paths-a1" "$scratch/paths-wt-b"
check "CLAUDE_CODE_SESSION_ID scopes the defaults" no_shared_path "$scratch/paths-claude" "$scratch/paths-none"
check "SELF_VERIFY_SESSION wins over CLAUDE_CODE_SESSION_ID" cmp -s "$scratch/paths-a1" \
  <(session_paths "$wt_a" "a$$" CLAUDE_CODE_SESSION_ID="claude$$")
check "no session id: each shell of one agent gets the same paths" same_paths "$scratch/paths-agent-x1" "$scratch/paths-agent-x2"
check "no session id: two agents share no path" no_shared_path "$scratch/paths-agent-x1" "$scratch/paths-agent-y"
check "no session id: an agent differs from its parent session" no_shared_path "$scratch/paths-agent-y" "$scratch/paths-none"
check "the default dir is under TMPDIR" grep -q "^SELF_VERIFY_DIR=$scratch/tmp/codans-self-verify-$uid-" "$scratch/paths-a1"
check "the default paths pass validation" sh -c '. "$1" && . "$2" && sv_validate_paths "$SELF_VERIFY_SOCKET" "$SELF_VERIFY_CACHE"' \
  _ "$scratch/paths-a1" "$scripts_dir/helpers.sh"
check "a zmx socket (<cache>/run/<uuid>) fits in 104 bytes" sh -c '. "$1" && test $((${#SELF_VERIFY_CACHE} + 41)) -lt 104' \
  _ "$scratch/paths-a1"
check "explicit path variables override the defaults" test "$(cd "$wt_a" && SELF_VERIFY_SESSION=x \
  SELF_VERIFY_DIR=/x/d SELF_VERIFY_SOCKET=/tmp/x.sock SELF_VERIFY_CACHE=/tmp/x-c bash -c \
  '. "$1" && echo "$SELF_VERIFY_DIR $SELF_VERIFY_SOCKET $SELF_VERIFY_CACHE"' _ "$scripts_dir/helpers.sh")" = "/x/d /tmp/x.sock /tmp/x-c"

# ---------- two concurrent agents, no session id ----------
# Two agents in one worktree, neither with a session variable, each in its
# own shells: launch; find the instance again; on "go", clean up. Neither
# sees a busy socket, and cleanup in one leaves the other running.
src="cd '$wt_a' && . '$scripts_dir/helpers.sh'"
for s in one two; do
  anchor "$src && mkdir -p \"\$SELF_VERIFY_DIR\" && cp '$scratch/sv/sv-tool' \"\$SELF_VERIFY_DIR/\" &&
      printf 'SELF_VERIFY_DIR=%s\nSELF_VERIFY_SOCKET=%s\nSELF_VERIFY_CACHE=%s\n' \"\$SELF_VERIFY_DIR\" \
        \"\$SELF_VERIFY_SOCKET\" \"\$SELF_VERIFY_CACHE\" >'$scratch/session-$s.env'
      sv_launch >'$scratch/launch-$s' 2>&1; echo \$? >'$scratch/launched-$s'" \
    "$src && sv_pid >'$scratch/pid-$s'; touch '$scratch/ready-$s'" \
    "until [ -e '$scratch/go-$s' ]; do sleep 0.1; done; $src && sv_cleanup >'$scratch/cleanup-$s' 2>&1" &
  eval "agent_$s=\$!"
done
for i in $(seq 1 300); do
  [ -e "$scratch/ready-one" ] && [ -e "$scratch/ready-two" ] && break
  sleep 0.1
done
check "agent one launches" test "$(cat "$scratch/launched-one" 2>/dev/null)" = 0
check "agent two launches while one runs" test "$(cat "$scratch/launched-two" 2>/dev/null)" = 0
pid_one="$(cat "$scratch/pid-one" 2>/dev/null)"
pid_two="$(cat "$scratch/pid-two" 2>/dev/null)"
check "a later shell of each agent finds its instance" sh -c '[ -n "$1" ] && [ -n "$2" ]' _ "$pid_one" "$pid_two"
check "the agents run two instances" test "$pid_one" != "$pid_two"
check "the agents share no path" no_shared_path "$scratch/session-one.env" "$scratch/session-two.env"
(. "$scratch/session-two.env" && cd "$SELF_VERIFY_CACHE" && exec sleep 300) &
daemon_two=$!
sleep 0.2
touch "$scratch/go-one"
wait "$agent_one"
check "agent one cleans up" grep -q 'cleanup done' "$scratch/cleanup-one"
check_not "agent one's instance is gone" kill -0 "$pid_one"
check "agent two's instance still runs" kill -0 "$pid_two"
check "agent two's daemon still runs" kill -0 "$daemon_two"
check "agent two's dir, socket, and cache are intact" sh -c '. "$1" && test -f "$SELF_VERIFY_DIR/conf/settings.json" &&
  test -S "$SELF_VERIFY_SOCKET" && test -d "$SELF_VERIFY_CACHE"' _ "$scratch/session-two.env"
touch "$scratch/go-two"
wait "$agent_two"
check "agent two cleans up" grep -q 'cleanup done' "$scratch/cleanup-two"
check_not "agent two's instance is gone" kill -0 "$pid_two"
check_not "agent two's daemon is gone" kill -0 "$daemon_two"

printf '\n%s failure(s)\n' "$failures"
[ "$failures" -eq 0 ]
