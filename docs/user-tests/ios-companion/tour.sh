#!/usr/bin/env bash
# Acceptance screenshots of the iOS companion against a real, isolated Mac
# instance: two projects with a real shell, a split, and a Claude Code-like
# agent session; then home, terminal, key bar, title menu, reconnecting
# after the Mac quits, and the removed state after the Mac revokes the phone.
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

AX="$SCRATCH/ax"
xcrun swiftc -O -o "$AX" "$REPO_ROOT/docs/user-tests/_shared/ax/ax.swift" || die "cannot build ax"

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
  cp "$REPO_ROOT/docs/user-tests/ios-companion/fake-claude.py" "$FAKEBIN/claude"
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
  rm -rf "$CACHE" && mkdir -p "$CACHE"
}

# ---------- Mac instance ----------
launch_mac() {
  pgrep -f "$APP/Contents/MacOS/Codans" >/dev/null && die "a Codans instance from $APP is already running"
  rm -f "$SOCK"
  CODANS_CONFIG_DIR="$CONF" CODANS_CACHE_DIR="$CACHE" \
    nohup "$APP/Contents/MacOS/Codans" >>"$SCRATCH/app.log" 2>&1 &
  MAC_PID=$!
  local _ up
  for _ in $(seq 1 100); do cli status >/dev/null 2>&1 && break; sleep 0.2; done
  up=$(cli status --json | jq -r '.data.uptimeSeconds')
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
  MAC_PID=""
}

cleanup() {
  [[ -n "${UI_PID:-}" ]] && kill "$UI_PID" 2>/dev/null
  quit_mac
  local id
  for id in $(jq -r '.devices[].id' "$CONF/remote-devices.json" 2>/dev/null); do
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$id" >/dev/null 2>&1
  done
  # zmx daemons outlive the app on purpose; the tour's own must not.
  pkill -f "$CACHE" 2>/dev/null
  rm -rf "$CACHE"
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

  tab=$(cli tab new shell --worktree "$wt" --json | jq -r '.data.id')
  shell=$(cli pane new --tab "$tab" --cwd "$WT_PATH" --json | jq -r '.data.id')
  sleep 1.5
  cli pane send "$shell" "git log --oneline -3 && ls src/checkout" >/dev/null
  cli pane send "$shell" "git status --short" >/dev/null

  cli agent launch "Claude Code" --worktree "$wt" --tab --json >/dev/null || die "agent launch failed"
  local _
  for _ in $(seq 1 40); do
    AGENT=$(cli tree --json | jq -r --arg w "$wt" '.data.projects[].worktrees[] | select(.id == $w) | .tabs[].panes[] | select(.agentKind != null) | .id' | head -1)
    [[ -n "$AGENT" ]] && cli pane read "$AGENT" 2>/dev/null | grep -q "Welcome to" && break
    sleep 0.5
  done
  cli pane read "$AGENT" 2>/dev/null | grep -q "Welcome to" || die "the agent pane never drew"
  cli pane focus "$AGENT" >/dev/null
}

# Issues a "View and type" pairing code; the clipboard is restored.
pairing_code() {
  local saved
  "$AX" press "$MAC_PID" "Pair New Device…" >/dev/null
  "$AX" wait "$MAC_PID" "Copy Pairing Code" 5 >/dev/null || return 1
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
  xcrun simctl uninstall "$SIM" com.gumpw.codans.mobile >/dev/null 2>&1
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1
  xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b >/dev/null
  xcrun simctl ui "$SIM" appearance "$APPEARANCE"
  xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 >/dev/null 2>&1
}

await_phone() {
  local step="$1" deadline=$((SECONDS + ${2:-240}))
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
