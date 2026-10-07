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

printf '\n%s failure(s)\n' "$failures"
[ "$failures" -eq 0 ]
