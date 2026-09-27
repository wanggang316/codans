#!/usr/bin/env bash
# End-to-end check of the iOS companion against a real Mac gateway:
# an isolated Debug instance of Codans with Remote Access on, pairing codes
# issued through its Settings pane (driven over the accessibility API), and
# the CodansMobile UI test on a simulator. Never touches the default dev /
# release sockets, config or zmx cache.
#
# Usage: [CASES="<case> ..."] harness.sh <Debug Codans.app path> [simulator UDID, on an iOS 26 runtime]
#
# CASES (space or comma separated, default: all) runs only the named cases,
# plus the pairing each one needs: the live cases reuse interactive's
# pairing, readonly-live read-only's, and rejected composer's (or
# interactive's when composer is not selected). revoke always runs last, to
# leave no device record or Keychain key behind.
#
# Cases:
#   interactive  pair "View and type", browse to the fixture pane, send a line,
#                and read the echoed output back on the Mac
#   read-only    pair "View only"; the phone must not offer an input bar
#   composer     pair "View and type", start the fake agent from the composer in
#                a new worktree; the Mac has the branch and the agent got the prompt
#   live-terminal   the Mac prints a marker in the pane; the phone's terminal shows it
#   live-input      the phone types `echo <marker>` + Return; the Mac pane has the output
#   modifier-keys   `sleep 30` in the pane; the phone taps ctrl then c; the shell answers
#   no-leader-steal the phone types, then the Mac window is resized; `stty size`
#                   follows the Mac and never the phone
#   tab-ops         New Tab, Split Right, Close Pane (confirmed) from the phone;
#                   checked in `codans tree --json`
#   readonly-live   a "View only" device streams the pane but shows no key bar
#   rejected        revoke the connected phone; it ends on "Pair again"
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

CASES="${CASES:-all}"
# want <case>...: whether any of the cases was selected.
want() {
  [[ "$CASES" == all ]] && return 0
  local c
  for c in "$@"; do [[ " ${CASES//,/ } " == *" $c "* ]] && return 0; done
  return 1
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }

unset CODANS_PANE_ID CODANS_CLI CODANS_WORKTREE_PATH CODANS_ROOT_PATH ZMX_DIR ZMX_SESSION TERM_PROGRAM TERM_PROGRAM_VERSION
export CODANS_SOCKET_PATH="$SOCK"
cli() { "$CLI" "$@"; }

# shellcheck source=../_shared/zmx-cleanup.sh
source "$REPO_ROOT/docs/user-tests/_shared/zmx-cleanup.sh"
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
  kill_zmx_sessions "$CACHE"
  rm -rf "$CACHE" && mkdir -p "$CACHE"
  rm -f "$SOCK"
  CODANS_CONFIG_DIR="$CONF" CODANS_CACHE_DIR="$CACHE" \
    nohup "$APP/Contents/MacOS/Codans" >"$SCRATCH/app.log" 2>&1 &
  MAC_PID=$!
  # The gateway logs at info level, which the unified log does not keep.
  log stream --level info --style compact \
    --predicate "processID == $MAC_PID AND subsystem == \"com.gumpw.codans.remote\"" \
    >"$SCRATCH/gateway.log" 2>&1 &
  LOG_PID=$!
  for _ in $(seq 1 100); do cli status >/dev/null 2>&1 && break; sleep 0.2; done
  local up; up=$(cli status --json | jq -r '.data.uptimeSeconds')
  awk -v u="$up" 'BEGIN { exit !(u + 0 < 30) }' || { echo "REFUSING: socket answered by an older instance"; exit 1; }
  echo "mac instance pid=$MAC_PID"

  local tab
  cli project add "$FIX" --json >/dev/null
  WT=$(cli tree --json | jq -r '.data.projects[0].worktrees[0].id')
  tab=$(cli tab new e2e --worktree "$WT" --json | jq -r '.data.id')
  PANE=$(cli pane new --tab "$tab" --cwd "$FIX" --json | jq -r '.data.id')
  [[ -n "$PANE" && "$PANE" != null ]] || { echo "could not create the fixture pane"; exit 1; }

  "$AX" menu "$MAC_PID" Codans "Settings…" >/dev/null
  "$AX" wait "$MAC_PID" "Remote Access" 10 >/dev/null
  "$AX" select-row "$MAC_PID" "Remote Access" >/dev/null
  "$AX" wait "$MAC_PID" "Pair New Device…" 10 >/dev/null || { echo "Remote Access pane did not open"; exit 1; }
}

quit_mac() {
  [[ -n "${UI_PID:-}" ]] && kill "$UI_PID" 2>/dev/null
  [[ -n "${LOG_PID:-}" ]] && kill "$LOG_PID" 2>/dev/null
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
  # zmx daemons outlive the app on purpose; the instance's own must not.
  kill_zmx_sessions "$CACHE"
  rm -rf "$CACHE"
  echo "quit mac instance"
}
# The simulator is booted by reset_sim; leave nothing of the run behind.
trap 'quit_mac; xcrun simctl shutdown "$SIM" >/dev/null 2>&1' EXIT

# Issues a pairing code with the given permission ("View only" or "View and
# type") and prints it. The clipboard is restored afterwards.
pairing_code() {
  local permission="$1" saved log="$SCRATCH/pairing.log"
  echo "--- $(date +%T) $UI_CASE: $permission" >>"$log"
  # The previous pairing's sheet (with its "Done") can still be closing, or
  # refuse the first press while another window is key; retry until the
  # new pairing sheet is up.
  local attempt opened=0
  for attempt in 1 2 3 4 5; do
    # The new sheet can open after the previous attempt stopped waiting; a
    # finished pairing's sheet shows "Done" instead.
    if ((attempt > 1)) && ! "$AX" wait "$MAC_PID" "Done" 0.3 >/dev/null 2>&1 &&
      "$AX" wait "$MAC_PID" "Copy Pairing Code" 1 >>"$log" 2>&1; then
      opened=1; break
    fi
    "$AX" press "$MAC_PID" "Done" >>"$log" 2>&1   # dismiss a finished pairing
    if "$AX" wait "$MAC_PID" "Pair New Device…" 3 >>"$log" 2>&1 &&
      "$AX" press "$MAC_PID" "Pair New Device…" >>"$log" 2>&1 &&
      "$AX" wait "$MAC_PID" "Copy Pairing Code" 15 >>"$log" 2>&1; then
      opened=1; break
    fi
    # A press on a SwiftUI button in a window that is not frontmost can be
    # dropped (the main window was just resized); bring Settings forward.
    "$AX" menu "$MAC_PID" Codans "Settings…" >/dev/null 2>&1
    sleep 1
  done
  ((opened)) || { "$AX" tree "$MAC_PID" >>"$log" 2>&1; return 1; }
  if [[ "$permission" != "View only" ]]; then
    # The first "View only" pop-up is the new pairing's own picker.
    "$AX" press "$MAC_PID" "View only" >>"$log" 2>&1
    "$AX" wait "$MAC_PID" "$permission" 3 >>"$log" 2>&1 && "$AX" press "$MAC_PID" "$permission" >>"$log" 2>&1
  fi
  saved="$(pbpaste)"
  "$AX" press "$MAC_PID" "Copy Pairing Code" >>"$log" 2>&1
  sleep 0.5
  pbpaste
  printf '%s' "$saved" | pbcopy
}

# ---------- phone ----------
# A fresh app with no pairing, and no SpringBoard prompt left over from an
# earlier `openurl`, which would otherwise answer the next one.
reset_sim() {
  # uninstall is a silent no-op on a shut-down simulator, which would keep
  # the last run's pairing (UserDefaults and Keychain) and have the app
  # connect with a revoked key while the test pairs. Boot first.
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  xcrun simctl uninstall "$SIM" com.gumpw.codans.mobile >/dev/null 2>&1
  if xcrun simctl get_app_container "$SIM" com.gumpw.codans.mobile >/dev/null 2>&1; then
    echo "cannot uninstall the app from $SIM"; exit 1
  fi
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1
  xcrun simctl boot "$SIM" && xcrun simctl bootstatus "$SIM" -b >/dev/null
}

# The UI test target is built once; every case then runs it without
# building, which saves a minute or so per case.
build_ui_tests() {
  (cd "$IOS_DIR" &&
    xcodebuild -workspace CodansMobile.xcworkspace -scheme CodansMobile -skipPackagePluginValidation \
      -destination "platform=iOS Simulator,id=$SIM" build-for-testing >"$SCRATCH/build-for-testing.log" 2>&1)
}

# start_ui_test <case> <test method> [NAME=value ...]
# Runs one RemoteEndToEndUITests method in the background. Each NAME=value
# reaches the test as CODANS_E2E_NAME. The test and the harness hand off
# through files in $SYNC (see await_phone / release).
start_ui_test() {
  local name="$1" method="$2"; shift 2
  local vars=() pair
  for pair in "$@"; do vars+=("TEST_RUNNER_CODANS_E2E_$pair"); done
  SYNC="$SCRATCH/sync/$name"
  UI_CASE="$name"
  rm -rf "$SYNC" && mkdir -p "$SYNC" "$SHOTS/$name"
  (cd "$IOS_DIR" &&
    env "${vars[@]}" \
      TEST_RUNNER_CODANS_E2E_PROJECT="$(basename "$FIX")" \
      TEST_RUNNER_CODANS_E2E_SYNC="$SYNC" \
      TEST_RUNNER_CODANS_E2E_SHOTS="$SHOTS/$name" \
      xcodebuild -workspace CodansMobile.xcworkspace -scheme CodansMobile -skipPackagePluginValidation \
        -destination "platform=iOS Simulator,id=$SIM" \
        -resultBundlePath "$SCRATCH/$name.xcresult" \
        test-without-building -only-testing:"CodansMobileUITests/RemoteEndToEndUITests/$method" \
        >"$SCRATCH/$name.log" 2>&1) &
  UI_PID=$!
}

# Waits for the running test and returns its status.
finish_ui_test() {
  wait "$UI_PID"
  local status=$?
  # Result bundles carry a screen recording; keep them only for failures.
  [[ $status == 0 ]] && rm -rf "$SCRATCH/$UI_CASE.xcresult"
  return $status
}

# run_ui_test <case> <test method> [NAME=value ...]: start and wait.
run_ui_test() {
  start_ui_test "$@"
  finish_ui_test
}

# run_pairing_test <case> <test method> <permission> [NAME=value ...]: like
# run_ui_test, but the test pairs first. The code is issued only once the
# app is up and asks for it: a code expires ten minutes after the Mac
# issues it, and the test runner can take that long to start.
run_pairing_test() {
  local name="$1" method="$2" permission="$3"; shift 3
  start_ui_test "$name" "$method" PAIR=1 "$@"
  if await_phone pair 900; then
    pairing_code "$permission" >"$SYNC/pairing-code"
    release pair
  fi
  finish_ui_test
}

# await_phone <step> [seconds]: waits until the test reaches <step>. Fails
# when the test ends first (it failed before the step) or on timeout.
await_phone() {
  local step="$1" budget="${2:-180}" deadline
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

# release <step>: lets the test continue past <step>.
release() { touch "$SYNC/$1.mac"; }

# Lines of the pane's screen, one per line.
pane_lines() { cli pane read "$1" 2>/dev/null; }

# wait_for_line <pane> <exact line> [seconds]
wait_for_line() {
  local deadline=$((SECONDS + ${3:-10}))
  until pane_lines "$1" | grep -qx -- "$2"; do
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

# The pane's PTY size as "rows cols", from `stty size` run in it.
stty_size() {
  cli pane send "$PANE" "stty size" --capture 2>/dev/null | grep -Eo '^[0-9]+ [0-9]+$' | tail -1
}

# Resizes the main window: the one without the Settings sidebar's Remote
# Access row. (The Pair New Device button is no marker: after a pairing
# the pane shows Done in its place until the next code is issued.)
resize_mac() { "$AX" resize "$MAC_PID" "$1" "$2" "Remote Access" >/dev/null; sleep 1.5; }

# Tab and pane counts of the fixture worktree, as "tabs panes".
tree_counts() {
  cli tree --json | jq -r --arg w "$WT" \
    '.data.projects[0].worktrees[] | select(.id == $w) | "\(.tabs | length) \([.tabs[].panes[]] | length)"'
}

# wait_for_counts <"tabs panes"> [seconds]
wait_for_counts() {
  local deadline=$((SECONDS + ${2:-10}))
  until [[ "$(tree_counts)" == "$1" ]]; do
    ((SECONDS < deadline)) || return 1
    sleep 0.5
  done
}

device_ids() { jq -r '.devices[].id' "$CONF/remote-devices.json" 2>/dev/null; }

# ---------- cases ----------
launch_mac
if ! build_ui_tests; then
  echo "cannot build the UI tests (see $SCRATCH/build-for-testing.log)"; exit 1
fi

# The phone opens a worktree on the pane it last viewed there, else on the
# Mac's focused pane; focus keeps a fresh install on the fixture pane.
cli pane focus "$PANE" >/dev/null

# --- "View and type": pairs, then the live cases run on the same pairing.
LIVE_CASES=(live-terminal live-input modifier-keys no-leader-steal tab-ops)
if want interactive "${LIVE_CASES[@]}" || { want rejected && ! want composer; }; then
  MARKER="hi-from-phone-$$"
  reset_sim
  if run_pairing_test interactive testPairBrowseReadAndSend "View and type" INPUT="echo $MARKER"; then
    ok "interactive: paired, browsed, sent a line"
  else
    bad "interactive UI test (see $SCRATCH/interactive.log)"
  fi
  if cli pane read "$PANE" | grep -qx "$MARKER"; then
    ok "interactive: the Mac pane printed the line sent from the phone"
  else
    bad "interactive: '$MARKER' not in the pane output"
  fi
fi

if want live-terminal; then
  # live-terminal: printed as two words so the typed command never contains
  # the marker itself; only the output does.
  start_ui_test live-terminal testShowsLiveOutput PAIRED=1 MARKER="live-$$"
  if await_phone attached; then
    cli pane send "$PANE" "printf '%s-%s\n' live $$" >/dev/null
    release attached
  fi
  if finish_ui_test; then
    ok "live-terminal: the phone showed output printed on the Mac"
  else
    bad "live-terminal (see $SCRATCH/live-terminal.log)"
  fi
fi

if want live-input; then
  if run_ui_test live-input testTypesIntoTheMacPane PAIRED=1 MARKER="typed-$$" && wait_for_line "$PANE" "typed-$$"; then
    ok "live-input: a line typed on the phone ran in the Mac pane"
  else
    bad "live-input: 'typed-$$' not in the pane output (see $SCRATCH/live-input.log)"
  fi
fi

if want modifier-keys; then
  interrupted=0
  start_ui_test modifier-keys testCtrlLatchInterruptsAForegroundJob PAIRED=1
  if await_phone ready; then
    cli pane send "$PANE" "sleep 30" >/dev/null
    sleep 1
    release ready
    if await_phone interrupted 60; then
      # A shell still in `sleep` only echoes the typed command; the output
      # line appears once the prompt is back.
      cli pane send "$PANE" "echo after-$$" >/dev/null
      wait_for_line "$PANE" "after-$$" 8 && interrupted=1
      release interrupted
    fi
  fi
  if finish_ui_test && [[ $interrupted == 1 ]]; then
    ok "modifier-keys: ctrl then c from the phone interrupted sleep"
  else
    bad "modifier-keys: the shell did not answer after ctrl-c (see $SCRATCH/modifier-keys.log)"
  fi
fi

if want no-leader-steal; then
  steal=""
  resize_mac 1400 900
  before=$(stty_size)
  start_ui_test no-leader-steal testLeavesTheSizeToTheMac PAIRED=1
  if await_phone typed; then
    after_input=$(stty_size)
    [[ -n "$before" && "$after_input" == "$before" ]] || steal="typing on the phone moved it: $before -> $after_input"
    release typed
    if await_phone resized; then
      resize_mac 1000 800
      narrow=$(stty_size)
      resize_mac 1400 900
      wide=$(stty_size)
      # The narrower window must give fewer columns, still far more than
      # a phone's portrait grid, and the wide one must restore the original.
      if [[ -z "$steal" ]] && ! { (( ${narrow#* } < ${before#* } && ${narrow#* } >= 60 )) && [[ "$wide" == "$before" ]]; }; then
        steal="did not follow the Mac: $before, narrow $narrow, wide again $wide"
      fi
      release resized
    else
      steal="the phone never got to the resize step"
    fi
  else
    steal="the phone never typed"
  fi
  if finish_ui_test && [[ -z "$steal" ]]; then
    ok "no-leader-steal: stty size stayed the Mac's ($before, narrow $narrow)"
  else
    bad "no-leader-steal: ${steal:-UI test failed} (see $SCRATCH/no-leader-steal.log)"
  fi
fi

if want tab-ops; then
  tab_ops=""
  start=$(tree_counts)
  tabs=${start% *} panes=${start#* }
  start_ui_test tab-ops testManagesTabsAndPanes PAIRED=1
  if await_phone new-tab; then
    # A new tab comes with one pane.
    wait_for_counts "$((tabs + 1)) $((panes + 1))" || tab_ops+=" new-tab($(tree_counts))"
    release new-tab
    if await_phone split; then
      wait_for_counts "$((tabs + 1)) $((panes + 2))" || tab_ops+=" split($(tree_counts))"
      release split
      if await_phone closed; then
        wait_for_counts "$((tabs + 1)) $((panes + 1))" || tab_ops+=" close($(tree_counts))"
        release closed
      else tab_ops+=" never-closed"; fi
    else tab_ops+=" never-split"; fi
  else tab_ops+=" never-new-tab"; fi
  if finish_ui_test && [[ -z "$tab_ops" ]]; then
    ok "tab-ops: New Tab, Split Right and Close Pane reached the Mac"
  else
    bad "tab-ops: from '$start':${tab_ops:- UI test failed} (see $SCRATCH/tab-ops.log)"
  fi
fi

# --- "View only"
if want read-only readonly-live; then
  cli pane focus "$PANE" >/dev/null
  reset_sim
  if run_pairing_test read-only testPairBrowseReadAndSend "View only"; then
    ok "read-only: no input bar"
  else
    bad "read-only UI test (see $SCRATCH/read-only.log)"
  fi
fi

if want readonly-live; then
  start_ui_test readonly-live testShowsLiveOutput PAIRED=1 READ_ONLY=1 MARKER="ro-$$"
  if await_phone attached; then
    cli pane send "$PANE" "printf '%s-%s\n' ro $$" >/dev/null
    release attached
  fi
  if finish_ui_test; then
    ok "readonly-live: a view-only device streams the pane without a key bar"
  else
    bad "readonly-live (see $SCRATCH/readonly-live.log)"
  fi
fi

# --- composer
if want composer; then
  PROMPT="e2e composer run $$"
  BRANCH="agent/e2e-composer-run-$$"
  reset_sim
  if run_pairing_test composer testComposerStartsAnAgentInANewWorktree "View and type" COMPOSER_PROMPT="$PROMPT"; then
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
fi

if [[ "$CASES" == all ]]; then
  active=$(jq '[.devices[] | select(.state == "active")] | length' "$CONF/remote-devices.json")
  [[ "$active" == 3 ]] && ok "all three pairings became active" || bad "expected 3 active devices, got $active"
fi

# --- revoke, with the composer's phone connected (rejected)
revoke_all() {
  local _
  for _ in $(device_ids); do
    "$AX" press "$MAC_PID" "Revoke…" >/dev/null && "$AX" wait "$MAC_PID" "Revoke" 3 >/dev/null &&
      "$AX" press "$MAC_PID" "Revoke" >/dev/null
    sleep 0.5
  done
}
ids=$(device_ids)
if want rejected; then
  start_ui_test rejected testShowsRemovedAfterRevocation PAIRED=1
  if await_phone live; then
    revoke_all
    echo "rejected: $(device_ids | wc -l | tr -d ' ') device record(s) left after revoking"
    release live
  fi
  if finish_ui_test; then
    ok "rejected: the revoked phone asks to pair again"
  else
    bad "rejected (see $SCRATCH/rejected.log)"
  fi
fi
revoke_all
if [[ -z "$(device_ids)" ]]; then ok "revoke: no device records left"; else bad "revoke: records remain"; fi
leftover=0
for id in $ids; do
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$id" >/dev/null 2>&1 && leftover=$((leftover+1))
done
[[ $leftover == 0 ]] && ok "revoke: Keychain keys deleted" || bad "revoke: $leftover Keychain key(s) remain"

echo
echo "passed $PASS, failed $FAIL — work files in $SCRATCH (screenshots in $SHOTS)"
[[ $FAIL == 0 ]]
