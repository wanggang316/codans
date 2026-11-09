#!/usr/bin/env bash
# Stress `pane send --capture` against a shell whose prompt draws slowly,
# the way a git-aware prompt does under load (#444).
#
# Usage: capture-stress.sh <Debug Codans.app path> [iterations] [prompt-secs]
#
# Each round sends one command, then a second one at once, while the first
# command's prompt is still being drawn. Before the #444 fix, the second
# capture came back empty with exit 0. Every round must print the output or
# fail with an error; an empty success counts as EMPTY and fails the run.
set -uo pipefail

APP="$1"
N="${2:-10}"
PROMPT_SECS="${3:-5}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$HERE/harness.sh"
CLI="$APP/Contents/Resources/bin/codans-dev"
export CODANS_CLI_REGRESSION_DIR="${CODANS_CLI_REGRESSION_DIR:-$(mktemp -d -t codans-capture-stress)}"
unset CODANS_PANE_ID ZMX_DIR ZMX_SESSION
CODANS_SOCKET_PATH="$(bash "$HARNESS" "$APP" paths | sed -n 's/^socket=//p')"
export CODANS_SOCKET_PATH
trap 'bash "$HARNESS" "$APP" quit >/dev/null' EXIT

bash "$HARNESS" "$APP" setup >/dev/null || exit 2
FIX="$CODANS_CLI_REGRESSION_DIR/run/fixture"
PID=$("$CLI" project add "$FIX" --json | jq -r .data.id)
WT=$("$CLI" worktree new stress/capture --project "$PID" --json | jq -r .data.id)
TAB=$("$CLI" tab new stress --worktree "$WT" --json | jq -r .data.id)
PANE=$("$CLI" pane new --project "$PID" --worktree "$WT" --tab "$TAB" --cwd "$FIX" --json -- /bin/zsh -f | jq -r .data.id)
sleep 2
# A busy loop of shell builtins: no child process, so the busy poller sees nothing.
"$CLI" pane send "$PANE" "zmodload zsh/datetime; precmd() { local t=\$EPOCHREALTIME; while (( EPOCHREALTIME - t < $PROMPT_SECS )); do :; done }" \
  --wait --wait-timeout 30 >/dev/null
sleep $((PROMPT_SECS + 1))

RESULTS="$CODANS_CLI_REGRESSION_DIR/capture-stress.tsv"
: >"$RESULTS"
ok=0 empty=0 error=0 other=0
for i in $(seq 1 "$N"); do
  "$CLI" pane send "$PANE" "echo PRE-$i" --capture --json >/dev/null 2>&1
  res=$("$CLI" pane send "$PANE" "echo CAP-$i" --capture --json 2>&1)
  rc=$?
  out=$(jq -r '.data.output // empty' <<<"$res" 2>/dev/null)
  if [[ $rc -ne 0 ]]; then kind=error; error=$((error + 1))
  elif grep -qx "CAP-$i" <<<"$out"; then kind=ok; ok=$((ok + 1))
  elif [[ -z "$out" ]]; then kind=EMPTY; empty=$((empty + 1))
  else kind=other; other=$((other + 1)); fi
  printf '%s\t%s\t%s\t%s\n' "$i" "$kind" "$rc" "$(tr '\n' ' ' <<<"$res")" >>"$RESULTS"
  printf '%-4s %-5s rc=%s\n' "$i" "$kind" "$rc"
  sleep $((PROMPT_SECS * 2 + 1))
done
echo "ok=$ok empty=$empty error=$error other=$other  (results: $RESULTS)"
[[ $empty -eq 0 && $other -eq 0 ]]
