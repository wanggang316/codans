#!/usr/bin/env bash
# End-to-end check of the iOS companion against a real Mac gateway:
# an isolated Debug instance of Codans with Remote Access on, pairing codes
# issued through its Settings pane (driven over the accessibility API), and
# the CodansMobile UI test on a simulator. Never touches the default dev /
# release sockets, config or zmx cache.
#
# Usage: harness.sh <Debug Codans.app path> [simulator UDID, on an iOS 26 runtime]
#
# Cases:
#   interactive  pair "View and type", browse to the fixture pane, send a line,
#                and read the echoed output back on the Mac
#   read-only    pair "View only"; the phone must not offer an input bar
#   composer     pair "View and type", start the fake agent from the composer in
#                a new worktree; the Mac has the branch and the agent got the prompt
#   revoke       revoke every device; their records and Keychain keys are gone
#
# Needs: a Debug build (`make mac-build`), the iOS project generated
# (`make ios-generate`), jq, and Accessibility permission for the terminal
# running this script (to press buttons in the test instance's Settings).
# Work files land in $CODANS_IOS_E2E_DIR (default: a fresh mktemp dir).
set -uo pipefail

APP="${1:?usage: harness.sh <Debug Codans.app path> [simulator UDID]}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="${CODANS_IOS_E2E_DIR:-$(mktemp -d -t codans-ios-e2e)}"
CLI="$APP/Contents/Resources/bin/codans-dev"
# AF_UNIX paths are capped near 104 bytes. The socket and the zmx cache
# (which holds one socket per pane) must stay short, so neither lives in
# $SCRATCH: a long cache path makes every pane exit at spawn.
SOCK="/tmp/codans-ie-$(id -u).sock"
CACHE="/tmp/cie-cache-$(id -u)"
CONF="$SCRATCH/conf"
FIX="$SCRATCH/fixture"
WTS="$SCRATCH/wts"
FAKEBIN="$SCRATCH/fakebin"
SHOTS="$SCRATCH/shots"
KEYCHAIN_SERVICE="com.gumpw.codans.remote.codans-dev"
IOS_DIR="$REPO_ROOT/apps/ios"
# The app needs iOS 26, and an older runtime can carry a device of the same
# name, so the default is picked from iOS 26 runtimes only.
SIM="${2:-$(xcrun simctl list devices available -j |
  jq -r '[.devices | to_entries[] | select(.key | test("iOS-26")) | .value[] |
    select(.name == "iPhone 17 Pro")][0].udid')}"
mkdir -p "$CONF" "$FIX" "$SHOTS" "$WTS" "$FAKEBIN"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }

unset CODANS_PANE_ID CODANS_CLI CODANS_WORKTREE_PATH CODANS_ROOT_PATH ZMX_DIR ZMX_SESSION TERM_PROGRAM TERM_PROGRAM_VERSION
export CODANS_SOCKET_PATH="$SOCK"
cli() { "$CLI" "$@"; }

AX="$SCRATCH/ax"
xcrun swiftc -O -o "$AX" "$REPO_ROOT/docs/user-tests/_shared/ax/ax.swift" || { echo "cannot build ax"; exit 1; }

# ---------- Mac instance ----------
launch_mac() {
  if pgrep -f "$APP/Contents/MacOS/Codans" >/dev/null; then
    echo "REFUSING: a Codans instance from $APP is already running"; exit 1
  fi
  git -C "$FIX" init -q -b main
  git -C "$FIX" -c user.name=e2e -c user.email=e2e@example.com commit -q --allow-empty -m init
  # A fake `claude` that prints its arguments, so a launch with a prompt is
  # visible in the pane without a real agent session.
  cat >"$FAKEBIN/claude" <<'AGENT'
#!/bin/sh
echo "FAKE-AGENT claude ARGS: $*"
while IFS= read -r line; do echo "RECEIVED: $line"; done
AGENT
  chmod +x "$FAKEBIN/claude"
  cat >"$CONF/settings.json" <<EOF
{
  "version": 3,
  "remoteAccess": { "enabled": true },
  "worktree": { "defaultWorktreesDirectory": "$WTS", "fetchRemoteOnCreate": false },
  "agents": { "profiles": [
    { "id": "11111111-1111-1111-1111-111111111111", "kind": "claude-code", "name": "Fake Claude",
      "envVars": { "PATH": "$FAKEBIN:/usr/bin:/bin" } }
  ] }
}
EOF
  rm -rf "$CACHE" && mkdir -p "$CACHE"
  rm -f "$SOCK"
  CODANS_CONFIG_DIR="$CONF" CODANS_CACHE_DIR="$CACHE" \
    nohup "$APP/Contents/MacOS/Codans" >"$SCRATCH/app.log" 2>&1 &
  MAC_PID=$!
  for _ in $(seq 1 100); do cli status >/dev/null 2>&1 && break; sleep 0.2; done
  local up; up=$(cli status --json | jq -r '.data.uptimeSeconds')
  awk -v u="$up" 'BEGIN { exit !(u + 0 < 30) }' || { echo "REFUSING: socket answered by an older instance"; exit 1; }
  echo "mac instance pid=$MAC_PID"

  local wt tab
  cli project add "$FIX" --json >/dev/null
  wt=$(cli tree --json | jq -r '.data.projects[0].worktrees[0].id')
  tab=$(cli tab new e2e --worktree "$wt" --json | jq -r '.data.id')
  PANE=$(cli pane new --tab "$tab" --cwd "$FIX" --json | jq -r '.data.id')
  [[ -n "$PANE" && "$PANE" != null ]] || { echo "could not create the fixture pane"; exit 1; }

  "$AX" menu "$MAC_PID" Codans "Settings…" >/dev/null
  "$AX" wait "$MAC_PID" "Remote Access" 10 >/dev/null
  "$AX" select-row "$MAC_PID" "Remote Access" >/dev/null
  "$AX" wait "$MAC_PID" "Pair New Device…" 10 >/dev/null || { echo "Remote Access pane did not open"; exit 1; }
}

quit_mac() {
  [[ -n "${MAC_PID:-}" ]] || return
  # A graceful quit withdraws the Bonjour advertisement. A killed app
  # leaves a stale record in mDNS for up to an hour, which the next run's
  # phone then finds first.
  kill -TERM "$MAC_PID" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$MAC_PID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL "$MAC_PID" 2>/dev/null
  # Keys of devices the cases did not revoke.
  for id in $(jq -r '.devices[].id' "$CONF/remote-devices.json" 2>/dev/null); do
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$id" >/dev/null 2>&1
  done
  rm -rf "$CACHE"
  echo "quit mac instance"
}
trap quit_mac EXIT

# Issues a pairing code with the given permission ("View only" or "View and
# type") and prints it. The clipboard is restored afterwards.
pairing_code() {
  local permission="$1" saved
  "$AX" press "$MAC_PID" "Done" >/dev/null 2>&1   # dismiss a finished pairing
  "$AX" press "$MAC_PID" "Pair New Device…" >/dev/null
  "$AX" wait "$MAC_PID" "Copy Pairing Code" 5 >/dev/null || return 1
  if [[ "$permission" != "View only" ]]; then
    # The first "View only" pop-up is the new pairing's own picker.
    "$AX" press "$MAC_PID" "View only" >/dev/null
    "$AX" wait "$MAC_PID" "$permission" 3 >/dev/null && "$AX" press "$MAC_PID" "$permission" >/dev/null
  fi
  saved="$(pbpaste)"
  "$AX" press "$MAC_PID" "Copy Pairing Code" >/dev/null
  sleep 0.5
  pbpaste
  printf '%s' "$saved" | pbcopy
}

# ---------- phone ----------
# A fresh app with no pairing, and no SpringBoard prompt left over from an
# earlier `openurl`, which would otherwise answer the next one.
reset_sim() {
  xcrun simctl uninstall "$SIM" com.gumpw.codans.mobile >/dev/null 2>&1
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1
  xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b >/dev/null
}

# run_ui_test <case> <test method> <pairing code> [line to send] [composer prompt]
run_ui_test() {
  local name="$1" method="$2" code="$3" line="${4:-}" prompt="${5:-}"
  mkdir -p "$SHOTS/$name"
  (cd "$IOS_DIR" &&
    TEST_RUNNER_CODANS_E2E_PAIRING_CODE="$code" \
    TEST_RUNNER_CODANS_E2E_PROJECT="$(basename "$FIX")" \
    TEST_RUNNER_CODANS_E2E_INPUT="$line" \
    TEST_RUNNER_CODANS_E2E_COMPOSER_PROMPT="$prompt" \
    TEST_RUNNER_CODANS_E2E_SHOTS="$SHOTS/$name" \
    xcodebuild -workspace CodansMobile.xcworkspace -scheme CodansMobile \
      -destination "platform=iOS Simulator,id=$SIM" \
      -resultBundlePath "$SCRATCH/$name.xcresult" \
      test -only-testing:"CodansMobileUITests/RemoteEndToEndUITests/$method" >"$SCRATCH/$name.log" 2>&1)
  local status=$?
  # Result bundles carry a screen recording; keep them only for failures.
  [[ $status == 0 ]] && rm -rf "$SCRATCH/$name.xcresult"
  return $status
}

device_ids() { jq -r '.devices[].id' "$CONF/remote-devices.json" 2>/dev/null; }

# ---------- cases ----------
launch_mac

MARKER="hi-from-phone-$$"
code=$(pairing_code "View and type")
reset_sim
if run_ui_test interactive testPairBrowseReadAndSend "$code" "echo $MARKER"; then
  ok "interactive: paired, browsed, sent a line"
else
  bad "interactive UI test (see $SCRATCH/interactive.log)"
fi
if cli pane read "$PANE" | grep -qx "$MARKER"; then
  ok "interactive: the Mac pane printed the line sent from the phone"
else
  bad "interactive: '$MARKER' not in the pane output"
fi

code=$(pairing_code "View only")
reset_sim
if run_ui_test read-only testPairBrowseReadAndSend "$code"; then
  ok "read-only: no input bar"
else
  bad "read-only UI test (see $SCRATCH/read-only.log)"
fi

PROMPT="e2e composer run $$"
BRANCH="agent/e2e-composer-run-$$"
code=$(pairing_code "View and type")
reset_sim
if run_ui_test composer testComposerStartsAnAgentInANewWorktree "$code" "" "$PROMPT"; then
  ok "composer: started an agent from the phone"
else
  bad "composer UI test (see $SCRATCH/composer.log)"
fi
new_wt=$(cli tree --json | jq -r --arg b "$BRANCH" '.data.projects[0].worktrees[] | select(.branch == $b) | .id')
if [[ -n "$new_wt" ]]; then ok "composer: the Mac created worktree $BRANCH"; else bad "composer: no worktree on branch $BRANCH"; fi
got_prompt=0
for pane in $(cli tree --json | jq -r --arg w "$new_wt" '.data.projects[0].worktrees[] | select(.id == $w) | .tabs[].panes[].id'); do
  cli pane read "$pane" | grep -q "FAKE-AGENT claude ARGS: .*$PROMPT" && got_prompt=1
done
[[ $got_prompt == 1 ]] && ok "composer: the agent started with the prompt" || bad "composer: no pane shows the agent with the prompt"

active=$(jq '[.devices[] | select(.state == "active")] | length' "$CONF/remote-devices.json")
[[ "$active" == 3 ]] && ok "all three pairings became active" || bad "expected 3 active devices, got $active"

ids=$(device_ids)
for _ in $ids; do
  "$AX" press "$MAC_PID" "Revoke…" >/dev/null && "$AX" wait "$MAC_PID" "Revoke" 3 >/dev/null &&
    "$AX" press "$MAC_PID" "Revoke" >/dev/null
  sleep 0.5
done
if [[ -z "$(device_ids)" ]]; then ok "revoke: no device records left"; else bad "revoke: records remain"; fi
leftover=0
for id in $ids; do
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$id" >/dev/null 2>&1 && leftover=$((leftover+1))
done
[[ $leftover == 0 ]] && ok "revoke: Keychain keys deleted" || bad "revoke: $leftover Keychain key(s) remain"

echo
echo "passed $PASS, failed $FAIL — work files in $SCRATCH (screenshots in $SHOTS)"
[[ $FAIL == 0 ]]
