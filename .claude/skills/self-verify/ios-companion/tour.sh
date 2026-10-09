#!/usr/bin/env bash
# Acceptance screenshots of the iOS companion against a real, isolated Mac
# instance: two projects, a real shell and a Claude Code-like agent
# session; then home, terminal, key bar, title menu, the shell tab,
# reconnecting after the Mac quits, and the removed state after the Mac
# revokes the phone.
# Uses the same isolation as harness.sh (private socket, config, zmx cache)
# and never touches the default dev / release instances.
#
# Usage: tour.sh <Debug Codans.app path> <simulator UDID> <light|dark> <out dir> [prefix]
# Screenshots land in <out dir> as <prefix>-<n>-<step>.png.
set -uo pipefail

APP="${1:?usage: tour.sh <Debug Codans.app path> <simulator UDID> <light|dark> <out dir> [prefix]}"
SIM="${2:?simulator UDID}"
APPEARANCE="${3:?light or dark}"
OUT="${4:?out dir}"
PREFIX="${5:-tour-$APPEARANCE}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="${CODANS_IOS_E2E_DIR:-$(mktemp -d -t codans-ios-tour)}"
CLI="$APP/Contents/Resources/bin/codans-dev"
# Short on purpose: AF_UNIX paths are capped near 104 bytes (see harness.sh).
SOCK="/tmp/codans-it-$(id -u).sock"
CACHE="/tmp/cit-cache-$(id -u)"
CONF="$SCRATCH/conf"
REPOS="$SCRATCH/repos"
FAKEBIN="$SCRATCH/fakebin"
SYNC="$SCRATCH/sync"
KEYCHAIN_SERVICE="com.gumpw.codans.remote.codans-dev"
IOS_DIR="$REPO_ROOT/apps/ios"
mkdir -p "$CONF" "$REPOS" "$FAKEBIN" "$OUT"

unset CODANS_PANE_ID CODANS_CLI CODANS_WORKTREE_PATH CODANS_ROOT_PATH ZMX_DIR ZMX_SESSION TERM_PROGRAM TERM_PROGRAM_VERSION
export CODANS_SOCKET_PATH="$SOCK"
cli() { "$CLI" "$@"; }
die() { echo "FAIL  $*"; exit 1; }

# shellcheck source=./zmx-cleanup.sh
source "$REPO_ROOT/.claude/skills/self-verify/ios-companion/zmx-cleanup.sh"
AX="$SCRATCH/ax"
xcrun swiftc -O -o "$AX" "$REPO_ROOT/.claude/skills/self-verify/ios-companion/ax.swift" || die "cannot build ax"

# ---------- fixtures ----------
repo() {
  local dir="$REPOS/$1"; shift
  git init -q -b main "$dir"
  local file
  for file in "$@"; do mkdir -p "$(dirname "$dir/$file")" && echo "// $file" >"$dir/$file"; done
  git -C "$dir" add -A
  git -C "$dir" -c user.name=tour -c user.email=tour@example.com commit -q -m "Initial import"
}

make_fixtures() {
  repo storefront package.json src/checkout/client.ts src/checkout/client.test.ts src/cart/store.ts README.md
  repo api-gateway go.mod cmd/gateway/main.go internal/auth/token.go README.md
  cp "$REPO_ROOT/.claude/skills/self-verify/ios-companion/fake-claude.py" "$FAKEBIN/claude"
  chmod +x "$FAKEBIN/claude"
  cat >"$CONF/settings.json" <<EOF
{
  "version": 3,
  "remoteAccess": { "enabled": true },
  "worktree": { "defaultWorktreesDirectory": "$SCRATCH/wts", "fetchRemoteOnCreate": false },
  "agents": { "profiles": [
    { "id": "11111111-1111-1111-1111-111111111111", "kind": "claude-code", "name": "Claude Code",
      "envVars": { "PATH": "$FAKEBIN:/usr/bin:/bin" } }
  ] }
}
EOF
  kill_zmx_sessions "$CACHE"
  rm -rf "$CACHE" && mkdir -p "$CACHE"
}

# ---------- Mac instance ----------
launch_mac() {
  pgrep -f "$APP/Contents/MacOS/Codans" >/dev/null && die "a Codans instance from $APP is already running"
  rm -f "$SOCK"
  CODANS_CONFIG_DIR="$CONF" CODANS_CACHE_DIR="$CACHE" \
    nohup "$APP/Contents/MacOS/Codans" -ApplePersistenceIgnoreState YES >>"$SCRATCH/app.log" 2>&1 &
  MAC_PID=$!
  # The gateway logs at info level, which the unified log does not keep.
  log stream --level info --style compact \
    --predicate "processID == $MAC_PID AND subsystem == \"com.gumpw.codans.remote\"" \
    >>"$SCRATCH/gateway.log" 2>&1 &
  LOG_PID=$!
  local _ up
  for _ in $(seq 1 100); do cli status >/dev/null 2>&1 && break; sleep 0.2; done
  up=$(cli status --json | jq -r '.data.uptimeSeconds')
  [[ "$up" =~ ^[0-9.]+$ ]] || die "the instance never answered on its socket"
  awk -v u="$up" 'BEGIN { exit !(u + 0 < 30) }' || die "socket answered by an older instance"
  # About 100 columns: the phone fits the Mac's grid to its width.
  "$AX" resize "$MAC_PID" 1000 760 >/dev/null
}

open_remote_settings() {
  "$AX" menu "$MAC_PID" Codans "Settings…" >/dev/null
  "$AX" wait "$MAC_PID" "Remote Access" 10 >/dev/null
  "$AX" select-row "$MAC_PID" "Remote Access" >/dev/null
  "$AX" wait "$MAC_PID" "Pair New Device…" 10 >/dev/null || die "Remote Access pane did not open"
}

quit_mac() {
  [[ -n "${MAC_PID:-}" ]] || return 0
  # A graceful quit withdraws the Bonjour advertisement (see harness.sh).
  kill -TERM "$MAC_PID" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$MAC_PID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$MAC_PID" 2>/dev/null
  [[ -n "${LOG_PID:-}" ]] && kill "$LOG_PID" 2>/dev/null
  MAC_PID="" LOG_PID=""
}

cleanup() {
  [[ -n "${UI_PID:-}" ]] && kill "$UI_PID" 2>/dev/null
  quit_mac
  local id
  for id in $(jq -r '.devices[].id' "$CONF/remote-devices.json" 2>/dev/null); do
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$id" >/dev/null 2>&1
  done
  # zmx daemons outlive the app on purpose; the tour's own must not.
  kill_zmx_sessions "$CACHE"
  rm -rf "$CACHE"
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1
}
trap cleanup EXIT

# A shell tab with some history, and the Claude Code-like agent in a tab of
# its own, focused so the phone opens on it.
populate() {
  local p wt tab shell
  for p in storefront api-gateway; do cli project add "$REPOS/$p" --json >/dev/null; done
  cli worktree new feat/checkout-retry --project storefront --json >/dev/null || die "worktree new failed"
  wt=$(cli tree --json | jq -r '.data.projects[] | select(.name == "storefront") | .worktrees[] | select(.branch == "feat/checkout-retry") | .id')
  [[ -n "$wt" ]] || die "no feat/checkout-retry worktree"
  WT_PATH=$(cli tree --json | jq -r --arg w "$wt" '.data.projects[].worktrees[] | select(.id == $w) | .path')

  # The new worktree opens with a shell tab; naming it keeps the host name
  # the shell puts in its title out of the tab menu.
  tab=$(cli tree --json | jq -r --arg w "$wt" '.data.projects[].worktrees[] | select(.id == $w) | .tabs[0].id')
  shell=$(cli tree --json | jq -r --arg w "$wt" '.data.projects[].worktrees[] | select(.id == $w) | .tabs[0].panes[0].id')
  [[ -n "$shell" && "$shell" != null ]] || die "the new worktree has no shell pane"
  cli tab rename "$tab" shell --project storefront --worktree "$wt" >/dev/null || die "tab rename failed"
  echo "export const MAX_ATTEMPTS = 3" >>"$WT_PATH/src/checkout/client.ts"
  sleep 1.5
  # No pager: git would otherwise leave the pane in less.
  cli pane send "$shell" "git --no-pager log --oneline -3 && ls src/checkout" >/dev/null
  sleep 1
  cli pane send "$shell" "git status --short" >/dev/null

  AGENT=$(cli agent launch "Claude Code" --worktree "$wt" --tab --json | jq -r '.data.paneID')
  [[ -n "$AGENT" && "$AGENT" != null ]] || die "agent launch failed"
  local _
  for _ in $(seq 1 40); do
    cli pane read "$AGENT" 2>/dev/null | grep -q "Welcome to" && break
    sleep 0.5
  done
  cli pane read "$AGENT" 2>/dev/null | grep -q "Welcome to" || die "the agent pane never drew"
  cli pane focus "$AGENT" >/dev/null
}

# Issues a "View and type" pairing code; the clipboard is restored.
pairing_code() {
  local saved attempt opened=0
  # On a loaded machine Settings can be slow to show the pane, or refuse the
  # first press; retry as harness.sh does.
  for attempt in 1 2 3 4 5; do
    # The sheet can open after the previous attempt stopped waiting.
    if "$AX" wait "$MAC_PID" "Copy Pairing Code" 1 >/dev/null ||
      { "$AX" wait "$MAC_PID" "Pair New Device…" 5 >/dev/null &&
        "$AX" press "$MAC_PID" "Pair New Device…" >/dev/null &&
        "$AX" wait "$MAC_PID" "Copy Pairing Code" 15 >/dev/null; }; then
      opened=1; break
    fi
    # A press on a SwiftUI button in a window that is not frontmost can be
    # dropped (the main window was just resized); bring Settings forward.
    "$AX" menu "$MAC_PID" Codans "Settings…" >/dev/null 2>&1
    sleep 1
  done
  ((opened)) || { "$AX" tree "$MAC_PID" >"$SCRATCH/ax-tree.txt" 2>&1; return 1; }
  "$AX" press "$MAC_PID" "View only" >/dev/null
  "$AX" wait "$MAC_PID" "View and type" 3 >/dev/null && "$AX" press "$MAC_PID" "View and type" >/dev/null
  saved="$(pbpaste)"
  "$AX" press "$MAC_PID" "Copy Pairing Code" >/dev/null
  sleep 0.5
  pbpaste
  printf '%s' "$saved" | pbcopy
}

revoke_all() {
  local _
  for _ in $(jq -r '.devices[].id' "$CONF/remote-devices.json" 2>/dev/null); do
    "$AX" press "$MAC_PID" "Revoke…" >/dev/null && "$AX" wait "$MAC_PID" "Revoke" 3 >/dev/null &&
      "$AX" press "$MAC_PID" "Revoke" >/dev/null
    sleep 0.5
  done
}

# ---------- phone ----------
reset_sim() {
  # uninstall is a silent no-op on a shut-down simulator, which would keep
  # the last run's pairing (UserDefaults and Keychain) and have the app
  # connect with a revoked key while the test pairs. Boot first.
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  xcrun simctl uninstall "$SIM" com.gumpw.codans.mobile >/dev/null 2>&1
  if xcrun simctl get_app_container "$SIM" com.gumpw.codans.mobile >/dev/null 2>&1; then
    echo "cannot uninstall the app from $SIM"; exit 1
  fi
  # The simulator can keep running an older test runner after a rebuild.
  xcrun simctl uninstall "$SIM" com.gumpw.codans.mobile-uitests.xctrunner >/dev/null 2>&1
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1
  xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b >/dev/null
  xcrun simctl ui "$SIM" appearance "$APPEARANCE"
  xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 >/dev/null 2>&1
}

await_phone() {
  local step="$1" budget="${2:-240}" deadline
  # Until the phone reaches its first step the test runner may still be
  # starting, which takes many minutes on a loaded machine; the runner's
  # liveness below is the real guard then.
  compgen -G "$SYNC/*.phone" >/dev/null || budget=3600
  deadline=$((SECONDS + budget))
  while [[ ! -e "$SYNC/$step.phone" ]]; do
    kill -0 "$UI_PID" 2>/dev/null || return 1
    ((SECONDS < deadline)) || return 1
    sleep 0.3
  done
}
release() { touch "$SYNC/$1.mac"; }

# ---------- tour ----------
make_fixtures
launch_mac
populate
open_remote_settings
reset_sim

rm -rf "$SYNC" && mkdir -p "$SYNC"
(cd "$IOS_DIR" &&
  TEST_RUNNER_CODANS_E2E_PAIR=1 \
  TEST_RUNNER_CODANS_E2E_PROJECT=storefront \
  TEST_RUNNER_CODANS_E2E_WORKTREE=checkout-retry \
  TEST_RUNNER_CODANS_E2E_TOUR_PREFIX="$PREFIX" \
  TEST_RUNNER_CODANS_E2E_SYNC="$SYNC" \
  TEST_RUNNER_CODANS_E2E_SHOTS="$OUT" \
  xcodebuild -workspace CodansMobile.xcworkspace -scheme CodansMobile -skipPackagePluginValidation \
    -destination "platform=iOS Simulator,id=$SIM" \
    test -only-testing:CodansMobileUITests/RemoteEndToEndUITests/testAcceptanceTour \
    >"$SCRATCH/tour.log" 2>&1) &
UI_PID=$!

# The code is issued once the app asks for it (see harness.sh).
await_phone pair 900 || die "the app never asked for a pairing code (see $SCRATCH/tour.log)"
pairing_code >"$SYNC/pairing-code" || die "no pairing code"
release pair
await_phone quit || die "the phone never reached the terminal (see $SCRATCH/tour.log)"
quit_mac
release quit
await_phone relaunched 120 || die "the phone never showed reconnecting (see $SCRATCH/tour.log)"
launch_mac
open_remote_settings
release relaunched
await_phone live 120 || die "the phone never reconnected (see $SCRATCH/tour.log)"
revoke_all
release live
wait "$UI_PID" || die "tour UI test failed (see $SCRATCH/tour.log)"
UI_PID=""
echo "PASS  tour $PREFIX — screenshots in $OUT"
