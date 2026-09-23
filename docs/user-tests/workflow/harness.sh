#!/usr/bin/env bash
# End-to-end run of the built-in workflows (review-loop, handoff, advisor)
# against an isolated Debug instance: private socket, scratch config and
# workflow directories, a fixture repo, and a fake `claude` that behaves as
# a workflow participant — it reads the injected line or its launch prompt,
# looks busy for a moment, then runs the exact `workflow deliver` command
# it was given. Never touches the default dev / release sockets or catalogs.
#
# Usage: harness.sh <Debug Codans.app path> [all|setup|quit]
#   all    launch the instance, run every phase, quit it (default)
#   setup  launch the instance and leave it running (manual probing)
#   quit   stop a running instance
#
# Work files land in $CODANS_WORKFLOW_TEST_DIR (default: a fresh mktemp dir);
# results.tsv there lists every case with wanted / got exit codes.
set -uo pipefail
APP="$1"
PHASE="${2:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="${CODANS_WORKFLOW_TEST_DIR:-$(mktemp -d -t codans-workflow-test)}"
mkdir -p "$SCRATCH"
CLI="$APP/Contents/Resources/bin/codans-dev"
# AF_UNIX paths are capped near 104 bytes, so the socket stays out of $SCRATCH.
SOCK="/tmp/codans-w-$(id -u).sock"
CONF="$SCRATCH/conf"
WORKFLOWS="$SCRATCH/workflows"
RUN="$SCRATCH/run"
FIX="$RUN/fixture"
WTS="$RUN/wts"
FAKEBIN="$RUN/fakebin"
FAKESTATE="$RUN/fakestate"
LOGS="$SCRATCH/logs"
RESULTS="$SCRATCH/results.tsv"
mkdir -p "$LOGS" "$RUN"

# ---------- helpers ----------
PASS=0; FAIL=0
t() {
  local id="$1" want="$2" desc="$3"; shift 3
  [[ "$1" == "--" ]] && shift
  local out="$LOGS/$id.out" err="$LOGS/$id.err"
  "$@" >"$out" 2>"$err"
  local got=$?
  local verdict="PASS"
  if [[ "$want" != "*" && "$got" != "$want" ]]; then verdict="FAIL"; fi
  [[ $verdict == PASS ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$verdict" "$want" "$got" "$desc" "$(printf '%q ' "$@")" >>"$RESULTS"
  printf '%-8s %-4s want=%-3s got=%-3s %s\n' "$id" "$verdict" "$want" "$got" "$desc"
  if [[ $verdict == FAIL ]]; then
    sed 's/^/    err: /' "$err" | head -3
    sed 's/^/    out: /' "$out" | head -3
  fi
}
jf() { jq -r ".data | $2" "$LOGS/$1.out"; }
note() { printf 'NOTE\t%s\n' "$*" >>"$RESULTS"; echo "  note: $*"; }
cli() { "$CLI" "$@"; }

# ---------- environment ----------
unset CODANS_PANE_ID CODANS_CLI CODANS_WORKTREE_PATH CODANS_ROOT_PATH ZMX_DIR ZMX_SESSION TERM_PROGRAM TERM_PROGRAM_VERSION CODANS_WORKFLOW_TOKEN CODANS_WORKFLOW_RUN CODANS_WORKFLOW_ROLE
export CODANS_SOCKET_PATH="$SOCK"
export CODANS_CONFIG_DIR="$CONF"
export CODANS_WORKFLOWS_DIR="$WORKFLOWS"

setup() {
  : >"$RESULTS"
  rm -rf "$CONF" "$RUN" "$WORKFLOWS"; mkdir -p "$CONF" "$RUN" "$WTS" "$FAKEBIN" "$FAKESTATE" "$LOGS" "$WORKFLOWS"
  bash "$REPO_ROOT/docs/user-tests/_shared/fixtures/setup/restore-repo-multi-branch.sh" "$FIX" >/dev/null
  git -C "$FIX" checkout -q feat/header-redesign
  # A participant: idles at a prompt, looks like Claude working while it
  # "thinks", then runs the delivery command it was handed. Verdicts are
  # popped from a queue file so a review can go issues → clean.
  cat >"$FAKEBIN/claude" <<'EOF'
#!/bin/sh
STATE="${FAKE_STATE:?}"
trace() { printf '%s [%s] %s\n' "$(date +%T)" "$$" "$*" >>"$STATE/trace.log"; }
work() {
  echo "esc to interrupt"
  sleep 3
  printf '\033[2J\033[H'
}
prompt() { echo "> "; }
deliver_from() {
  cmd=$(printf '%s\n' "$1" | grep -oE 'CODANS_WORKFLOW_TOKEN=[^ ]+ [^ ]+ workflow deliver( --verdict [^ ]+)? -' | tail -1)
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *--verdict*)
      verdict=$(head -1 "$STATE/verdicts" 2>/dev/null); [ -n "$verdict" ] || verdict=clean
      sed -i '' '1d' "$STATE/verdicts" 2>/dev/null
      cmd=$(printf '%s' "$cmd" | sed "s/--verdict [^ ]*/--verdict $verdict/")
      ;;
  esac
  echo "DELIVERING: $cmd"; trace "DELIVERING: $cmd"
  sh -c "$cmd" <<'BODY'
## Findings
- src/app.swift:1 — looks fine
## Changes
- addressed the findings
## Objective
Finish the fake task.
## Current State
Everything is fake.
## Next Steps
- nothing
## Advice
- keep it simple
## Risks
- none
## Summary
done
BODY
  echo "DELIVER-EXIT: $?"
}
echo "FAKE CLAUDE started"; trace "STARTED argc=$#"
if [ $# -gt 0 ]; then
  echo "PROMPT: $*"; trace "PROMPT: $*"
  work
  deliver_from "$*"
fi
prompt
while IFS= read -r line; do
  echo "RECEIVED: $line"; trace "RECEIVED: $line"
  work
  deliver_from "$line" || true
  prompt
done
EOF
  chmod +x "$FAKEBIN/claude"
  cat >"$CONF/settings.json" <<EOF
{
  "version": 3,
  "worktree": { "defaultWorktreesDirectory": "$WTS", "fetchRemoteOnCreate": false },
  "agents": { "profiles": [
    { "id": "11111111-1111-1111-1111-111111111111", "kind": "claude-code", "name": "Fake Claude",
      "envVars": { "PATH": "$FAKEBIN:/usr/bin:/bin", "FAKE_STATE": "$FAKESTATE" } },
    { "id": "22222222-2222-2222-2222-222222222222", "kind": "claude-code", "name": "Real Claude",
      "executionModeID": "bypass", "extraArguments": "-p" }
  ] }
}
EOF
}

# The test instance is known only by the pid this script started. Matching on
# the bundle path is not enough: a developer's own dev app often runs from the
# same DerivedData bundle, and quitting "whatever runs that path" killed it.
test_app_pid() {
  local pid; pid=$(cat "$SCRATCH/app.pid" 2>/dev/null) || return 1
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
launch_app() {
  if test_app_pid >/dev/null; then
    echo "test app already running pid=$(test_app_pid)"; return
  fi
  rm -f "$SOCK"
  nohup "$APP/Contents/MacOS/Codans" >"$SCRATCH/app.log" 2>&1 &
  APP_PID=$!
  echo "$APP_PID" >"$SCRATCH/app.pid"
  echo "launched test app pid=$APP_PID"
  for _ in $(seq 1 100); do
    if cli doctor --json 2>/dev/null | jq -e '.data | .socketStatus == "ok"' >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  local up; up=$(cli status --json | jq -r '.data | .uptimeSeconds')
  awk -v u="$up" 'BEGIN{ if (u+0 > 30) { print "uptime too high: " u; exit 1 } }' || { echo "REFUSING: socket answered by an older instance"; exit 1; }
}
quit_app() {
  local pid; pid=$(test_app_pid) || { echo "no test app running"; return; }
  kill -TERM "$pid" && sleep 2
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid"
  rm -f "$SCRATCH/app.pid"
  echo "quit test app"
}
wait_text() { # wait_text <pane> <needle> [secs]
  local pane="$1" needle="$2" secs="${3:-10}"
  for _ in $(seq 1 $((secs*5))); do
    if cli pane read "$pane" 2>/dev/null | grep -q -- "$needle"; then return 0; fi
    sleep 0.2
  done
  return 1
}
wait_state() { # wait_state <run-id> <state> [secs] — succeeds when the run reaches the state
  local run="$1" want="$2" secs="${3:-120}"
  for _ in $(seq 1 "$secs"); do
    local state; state=$(cli workflow status "$run" --json 2>/dev/null | jq -r '.data.run.state // empty')
    [[ "$state" == "$want" ]] && return 0
    case "$state" in completed|cancelled|skipped|iteration_limit_reached|failed|interrupted)
      echo "  run ended as $state while waiting for $want"; cli workflow status "$run" --json | jq -c '.data.run.attention' ; return 1;; esac
    sleep 1
  done
  echo "  timed out waiting for $want (last: $state)"; return 1
}

# Optional catalog watcher: with WF_WATCH=1, records worktree + pane ids
# twice a second to logs/catalog.log so a vanished pane can be dated.
start_watcher() {
  [[ "${WF_WATCH:-0}" == 1 ]] || return 0
  ( while :; do
      printf '%s %s\n' "$(date +%T)" "$(cli tree --json 2>/dev/null | jq -c '[.. | objects | select(has("tabs")) | {w: .id[0:8], panes: [.tabs[].panes[].id[0:8]]}]')" >>"$LOGS/catalog.log"
      sleep 0.5
    done ) &
  WATCHER_PID=$!
}
stop_watcher() { [[ -n "${WATCHER_PID:-}" ]] && kill "$WATCHER_PID" 2>/dev/null; }

# ---------- phases ----------
phase_setup() {
  echo "== project / author pane"
  t S01 0 "project add" -- cli project add "$FIX" --json
  PID=$(jf S01 .id); echo "  project id: $PID"
  t S02 0 "worktree new wf/test" -- cli worktree new wf/test --project "$PID" --json
  WT=$(jf S02 .id); WTPATH=$(jf S02 .path); echo "  worktree=$WT path=$WTPATH"
  t S03 0 "workflow list shows the three built-ins" -- bash -c "$CLI workflow list --json | jq -e '([.data.workflows[].id]|sort==[\"advisor\",\"handoff\",\"review-loop\"]) and all(.data.workflows[]; .isValid and .scope==\"bundle\")'"
  t S04 0 "author: launch Fake Claude" -- cli agent launch 'Fake Claude' --background --project "$PID" --worktree "$WT" --json
  AUTHOR=$(jf S04 .paneID); echo "  author pane: $AUTHOR"
  t S05 0 "author fake started" -- wait_text "$AUTHOR" 'FAKE CLAUDE started' 15
  t S06 0 "author is detected as claude and idle" -- bash -c "for i in \$(seq 1 100); do $CLI agent status --json | jq -e '.data.agents[]|select(.paneID==\"$AUTHOR\" and .agent==\"claude-code\" and .state==\"idle\")' >/dev/null 2>&1 && exit 0; sleep 0.3; done; $CLI agent status --json; exit 1"
  echo "== admission errors"
  t E01 2 "run unknown workflow -> 2 WORKFLOW_NOT_FOUND" -- bash -c "out=\$($CLI workflow run nope $AUTHOR --json); rc=\$?; jq -e '.error.code==\"WORKFLOW_NOT_FOUND\"' <<<\"\$out\" >/dev/null && exit \$rc; echo \"\$out\"; exit 99"
  t E02 1 "run advisor without its required input -> 1 INPUT_REQUIRED" -- bash -c "out=\$($CLI workflow run advisor $AUTHOR --role advisor='Fake Claude' --json); rc=\$?; jq -e '.error.code==\"INPUT_REQUIRED\"' <<<\"\$out\" >/dev/null && exit \$rc; echo \"\$out\"; exit 99"
  t E03 1 "run review-loop from a worktree (no pane) -> SOURCE_REQUIRED" -- bash -c "out=\$($CLI workflow run review-loop $WT --json); rc=\$?; jq -e '.error.code==\"SOURCE_REQUIRED\"' <<<\"\$out\" >/dev/null && exit \$rc; echo \"\$out\"; exit 99"
  t E04 0 "status of a random run id -> RUN_NOT_FOUND" -- bash -c "out=\$($CLI workflow status \$(uuidgen) --json); jq -e '.error.code==\"RUN_NOT_FOUND\"' <<<\"\$out\""
}

phase_review_loop() {
  echo "== review-loop (issues → clean)"
  printf 'issues\nclean\n' >"$FAKESTATE/verdicts"
  t R01 0 "run review-loop from the author pane" -- cli workflow run review-loop "$AUTHOR" --role reviewer='Fake Claude' --input max-rounds=2 --json
  RUN1=$(jf R01 .runID); echo "  run: $RUN1"
  t R02 0 "bindings: author=current pane, reviewer=Fake Claude" -- bash -c "jq -e '(.data.bindings|map(select(.role==\"author\"))[0].paneID==\"$AUTHOR\") and (.data.bindings|map(select(.role==\"reviewer\"))[0].profileName==\"Fake Claude\")' '$LOGS/R01.out'"
  t R03 0 "run completes" -- wait_state "$RUN1" completed 150
  t R04 0 "status: review verdict clean at ordinal 3, fixes delivered" -- bash -c "$CLI workflow status $RUN1 --json | jq -e '(.data.run.deliveries|map(select(.name==\"review\"))[0]|.verdict==\"clean\" and .ordinal==3) and (.data.run.deliveries|map(select(.name==\"fixes\"))|length==1)'"
  t R05 0 "deliveries on disk under the worktree" -- bash -c "test -f '$WTPATH/.codans/workflow-runs/$RUN1/deliveries/review.md' && test -f '$WTPATH/.codans/workflow-runs/$RUN1/deliveries/review.1.md' && test -f '$WTPATH/.codans/workflow-runs/$RUN1/deliveries/fixes.2.md' && grep -q '## Findings' '$WTPATH/.codans/workflow-runs/$RUN1/deliveries/review.md'"
  t R06 0 "log.md records the loop" -- bash -c "grep -q 'accepted' '$WTPATH/.codans/workflow-runs/$RUN1/log.md' && grep -c 'step' '$WTPATH/.codans/workflow-runs/$RUN1/log.md' >/dev/null"
  t R07 0 "the author's instruction was materialized and delivered" -- bash -c "test -f '$WTPATH/.codans/workflow-runs/$RUN1/instructions/fix.2.md' && grep -q 'injecting into author' '$WTPATH/.codans/workflow-runs/$RUN1/log.md'"
  t R08 0 ".codans/.gitignore lets workflows/ through" -- bash -c "grep -qx '!workflows/' '$WTPATH/.codans/.gitignore'"
  t R09 2 "deliver against the finished run -> RUN_NOT_FOUND" -- bash -c "out=\$(echo body | $CLI workflow deliver - --run $RUN1 --step kickoff --json); rc=\$?; jq -e '.error.code==\"RUN_NOT_FOUND\"' <<<\"\$out\" >/dev/null && exit \$rc; echo \"\$out\"; exit 99"
}

phase_handoff() {
  echo "== handoff (briefing → save → receiver)"
  t H01 0 "run handoff from the author pane" -- cli workflow run handoff "$AUTHOR" --role receiver='Fake Claude' --json
  RUN2=$(jf H01 .runID); echo "  run: $RUN2"
  t H02 0 "run completes" -- wait_state "$RUN2" completed 120
  t H03 0 "handoff packet saved" -- bash -c "test -f '$WTPATH/.codans/handoff/current.md' && grep -q '## Objective' '$WTPATH/.codans/handoff/current.md' && test -f '$WTPATH/.codans/handoff/context.md'"
  t H04 0 "save step succeeded with exit 0" -- bash -c "$CLI workflow status $RUN2 --json | jq -e '.data.run.steps|map(select(.id==\"save\"))[0].outcome==\"success\"'"
  t H05 0 "receiver launched (a second Fake Claude pane exists)" -- bash -c "$CLI agent status --json | jq -e '[.data.agents[]|select(.agent==\"claude-code\")]|length>=2'"
}

phase_advisor() {
  echo "== advisor (question → advice → back to the asker)"
  t V01 0 "run advisor from the author pane" -- cli workflow run advisor "$AUTHOR" --role advisor='Fake Claude' --input question='Should we split the module?' --json
  RUN3=$(jf V01 .runID); echo "  run: $RUN3"
  t V02 0 "run completes" -- wait_state "$RUN3" completed 120
  t V03 0 "advice delivered" -- bash -c "test -f '$WTPATH/.codans/workflow-runs/$RUN3/deliveries/advice.md' && grep -q '## Advice' '$WTPATH/.codans/workflow-runs/$RUN3/deliveries/advice.md'"
  t V04 0 "the asker got the pointer line" -- wait_text "$AUTHOR" 'advisor answered' 10
  t V05 0 "workflow runs lists the three runs" -- bash -c "$CLI workflow runs --worktree $WT --json | jq -e '[.data.runs[].runID]|length>=3'"
}

case "$PHASE" in
  setup) setup; launch_app; phase_setup ;;
  quit) quit_app ;;
  all)
    setup; launch_app; start_watcher
    phase_setup; phase_review_loop; phase_handoff; phase_advisor
    stop_watcher; quit_app
    echo; echo "PASS=$PASS FAIL=$FAIL  results: $RESULTS"
    [[ $FAIL -eq 0 ]]
    ;;
esac
