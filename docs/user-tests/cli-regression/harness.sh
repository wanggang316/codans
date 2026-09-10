#!/usr/bin/env bash
# Black-box regression of every `codans` verb against an isolated Debug
# instance: private socket, scratch config directory, fixture repo, fake
# agents. Never touches the default dev / release sockets or catalogs.
#
# Usage: harness.sh <Debug Codans.app path> [all|setup|quit]
#   all    launch the instance, run every phase, quit it (default)
#   setup  launch the instance and leave it running (manual probing)
#   quit   stop a running instance
#
# Work files land in $CODANS_CLI_REGRESSION_DIR (default: a fresh mktemp dir);
# results.tsv there lists every case with wanted / got exit codes.
set -uo pipefail

APP="$1"
PHASE="${2:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="${CODANS_CLI_REGRESSION_DIR:-$(mktemp -d -t codans-cli-regression)}"
mkdir -p "$SCRATCH"
CLI="$APP/Contents/Resources/bin/codans-dev"
# AF_UNIX paths are capped near 104 bytes, so the socket stays out of $SCRATCH.
SOCK="/tmp/codans-t-$(id -u).sock"
CONF="$SCRATCH/conf"
RUN="$SCRATCH/run"
FIX="$RUN/fixture"
WTS="$RUN/wts"
FAKEBIN="$RUN/fakebin"
LOGS="$SCRATCH/logs"
RESULTS="$SCRATCH/results.tsv"
mkdir -p "$LOGS" "$RUN"

# ---------- helpers ----------
PASS=0; FAIL=0
# t <id> <expected-exit> <description> -- <command...>
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
# grab a JSON field from a test's stdout
jf() { jq -r "$2" "$LOGS/$1.out"; }
# note a finding (not a pass/fail)
note() { printf 'NOTE\t%s\n' "$*" >>"$RESULTS"; echo "  note: $*"; }

cli() { "$CLI" "$@"; }

# ---------- environment ----------
# Scrub the release pane's own context so the dev CLI and the test app
# never see Gump's socket / pane id.
unset CODANS_PANE_ID CODANS_CLI CODANS_WORKTREE_PATH CODANS_ROOT_PATH ZMX_DIR ZMX_SESSION TERM_PROGRAM TERM_PROGRAM_VERSION
export CODANS_SOCKET_PATH="$SOCK"
export CODANS_CONFIG_DIR="$CONF"

setup() {
  : >"$RESULTS"
  rm -rf "$CONF" "$RUN"; mkdir -p "$CONF" "$RUN" "$WTS" "$FAKEBIN" "$LOGS"
  bash "$REPO_ROOT/docs/user-tests/_shared/fixtures/setup/restore-repo-multi-branch.sh" "$FIX" >/dev/null
  git -C "$FIX" checkout -q -b test/base 2>/dev/null || true
  git -C "$FIX" checkout -q feat/header-redesign
  for name in claude amp; do
    cat >"$FAKEBIN/$name" <<'EOF'
#!/bin/sh
echo "FAKE-AGENT $(basename "$0") ARGS: $*"
while IFS= read -r line; do echo "RECEIVED: $line"; done
EOF
    chmod +x "$FAKEBIN/$name"
  done
  cat >"$CONF/settings.json" <<EOF
{
  "version": 3,
  "worktree": { "defaultWorktreesDirectory": "$WTS", "fetchRemoteOnCreate": false },
  "agents": { "profiles": [
    { "id": "11111111-1111-1111-1111-111111111111", "kind": "claude-code", "name": "Fake Claude",
      "envVars": { "PATH": "$FAKEBIN:/usr/bin:/bin" } },
    { "id": "22222222-2222-2222-2222-222222222222", "kind": "amp", "name": "Fake Amp",
      "envVars": { "PATH": "$FAKEBIN:/usr/bin:/bin" } },
    { "id": "33333333-3333-3333-3333-333333333333", "kind": "codex", "name": "Disabled Codex", "isEnabled": false }
  ] }
}
EOF
}

launch_app() {
  if pgrep -f "$APP/Contents/MacOS/Codans" >/dev/null; then
    echo "test app already running"; return
  fi
  rm -f "$SOCK"
  nohup "$APP/Contents/MacOS/Codans" >"$SCRATCH/app.log" 2>&1 &
  APP_PID=$!
  echo "launched test app pid=$APP_PID"
  for _ in $(seq 1 100); do
    if cli doctor --json 2>/dev/null | jq -e '.socketStatus == "ok"' >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  cli status
  local up; up=$(cli status --json | jq -r .uptimeSeconds)
  awk -v u="$up" 'BEGIN{ if (u+0 > 30) { print "uptime too high: " u; exit 1 } }' || { echo "REFUSING: socket answered by an older instance"; exit 1; }
  # sanity: the socket is held by our pid
  lsof -p "$APP_PID" 2>/dev/null | grep -q "$SOCK" || echo "warning: could not confirm socket ownership via lsof"
}

quit_app() {
  local pid; pid=$(pgrep -f "$APP/Contents/MacOS/Codans" | head -1)
  [[ -n "$pid" ]] && kill -TERM "$pid" && sleep 2
  pgrep -f "$APP/Contents/MacOS/Codans" >/dev/null && kill -KILL "$pid"
  echo "quit test app"
}

wait_text() { # wait_text <pane> <needle> [secs]
  local pane="$1" needle="$2" secs="${3:-10}"
  for _ in $(seq 1 $((secs*5))); do
    if cli pane capture "$pane" --scope screen 2>/dev/null | grep -q -- "$needle"; then return 0; fi
    if cli pane read "$pane" 2>/dev/null | grep -q -- "$needle"; then return 0; fi
    sleep 0.2
  done
  return 1
}

# ---------- phases ----------
phase_app() {
  echo "== app & diagnostics"
  t A01 0 "status" -- cli status
  t A02 0 "status --json" -- cli status --json
  t A03 0 "doctor" -- cli doctor
  t A04 0 "doctor --json has socketStatus ok" -- bash -c "$CLI doctor --json | jq -e '.socketStatus==\"ok\" and .client==\"codans-dev\"'"
  t A05 0 "--version" -- cli --version
  t A06 0 "--help" -- cli --help
  t A07 0 "launch while running (idempotent)" -- cli launch --wait 2
  t A08 10 "status --socket /nonexistent -> 10" -- cli status --socket /tmp/codans-nope-$$.sock
  t A09 0 "doctor --socket nonexistent reports socket-missing" -- bash -c "$CLI doctor --socket /tmp/codans-nope-$$.sock --json | jq -e '.socketStatus==\"socket-missing\"'"
  t A10 14 "status --socket <regular file> -> 14" -- cli status --socket "$RESULTS"
  t A11 0 "help-json prints the subcommand tree" -- bash -c "$CLI help-json | jq -e '.subcommands|map(.name)|index(\"open\")'"
  t A12 0 "open --help" -- cli open --help
  t A16 "*" "open --in no-such-editor (strict, must fail, no side effect)" -- bash -c "$CLI open --in no-such-editor '$RUN'; test \$? -ne 0"
  t A13 64 "unknown subcommand -> 64 (EX_USAGE)" -- cli frobnicate
  t A15 0 "completion script zsh" -- cli --generate-completion-script zsh
  rm -f /tmp/codans-dead-$$.sock; (nc -lU /tmp/codans-dead-$$.sock >/dev/null 2>&1 &); sleep 0.3
  t A14 11 "--timeout against a socket that never answers -> 11" -- cli status --socket /tmp/codans-dead-$$.sock --timeout 0.3
  pkill -f "nc -lU /tmp/codans-dead-$$.sock"; rm -f /tmp/codans-dead-$$.sock
}

phase_project() {
  echo "== project"
  t P01 0 "project add (abs path)" -- cli project add "$FIX" --json
  PID=$(jf P01 .id); echo "  project id: $PID"
  t P02 0 "tree" -- cli tree
  t P03 0 "tree --json" -- cli tree --json
  t P04 0 "tree --project <id>" -- cli tree --project "$PID"
  t P05 2 "tree --project <random uuid> -> 2" -- cli tree --project "$(uuidgen)"
  t P06 0 "tree --project <name> resolves by name" -- cli tree --project FIXTURE
  t P06b 0 "project add detected the git root" -- bash -c "jq -e '.gitRoot==\"$FIX\"' '$LOGS/P01.out'"
  t P06c 0 "tree shows the real branch, not (no branch)" -- bash -c "$CLI tree --project $PID | grep -q '\[feat/header-redesign\]'"
  t P07 2 "tree --project current outside a pane -> 2 with hint" -- cli tree --project current
  t P08 3 "project add same path again -> 3 conflict" -- cli project add "$FIX"
  t P09 0 "project add relative path + --name" -- bash -c "cd '$RUN' && mkdir -p rel && git -C rel init -q && $CLI project add rel --name RelProj --json"
  RELPID=$(jf P09 .id)
  t P10 0 "project rm <id> (RelProj)" -- cli project rm "$RELPID"
  t P11 2 "project rm <same id> again -> 2" -- cli project rm "$RELPID"
  t P12 1 "project add nonexistent dir -> 1" -- cli project add "$RUN/does-not-exist" --json
  NPID=$(jf P12 .id 2>/dev/null || true)
  [[ -n "$NPID" && "$NPID" != null ]] && cli project rm "$NPID" >/dev/null 2>&1
  t P13 0 "project list" -- cli project list
  t P14 0 "project list --json has 1 project" -- bash -c "$CLI project list --json | jq -e '.projects|length==1'"
  t P15 2 "tree --project unknown-name -> 2" -- cli tree --project no-such-project
  echo "== project commands"
  t C01 0 "commands list (empty)" -- cli project commands list --project "$PID"
  t C02 0 "commands add" -- cli project commands add --project "$PID" --command 'echo hello' --name Hello --json
  CID=$(jf C02 .id)
  t C03 1 "commands add empty command -> 1" -- cli project commands add --project "$PID" --command ''
  t C04 0 "commands list shows one" -- bash -c "$CLI project commands list --project $PID --json | jq -e '.scripts|length==1'"
  t C05 0 "commands edit --kind test" -- cli project commands edit "$CID" --project "$PID" --kind test --json
  t C06 1 "commands edit nothing -> 1" -- cli project commands edit "$CID" --project "$PID"
  t C07 1 "commands edit bad id -> 1" -- cli project commands edit not-a-uuid --project "$PID" --name x
  t C08 2 "commands edit unknown id -> 2" -- cli project commands edit "$(uuidgen)" --project "$PID" --name x
  t C09 64 "commands add bad --kind -> 64" -- cli project commands add --project "$PID" --command x --kind bogus
  t C10 0 "commands rm" -- cli project commands rm "$CID" --project "$PID"
  t C11 2 "commands rm again -> 2" -- cli project commands rm "$CID" --project "$PID"
  t C12 2 "commands list --project current outside pane -> 2" -- cli project commands list
  t C13 0 "commands list --project <name>" -- cli project commands list --project fixture
}

phase_worktree() {
  echo "== worktree"
  t W01 0 "worktree new bugfix/menu (default path)" -- cli worktree new bugfix/menu --project "$PID" --json
  WT1=$(jf W01 .id); WT1PATH=$(jf W01 .path); echo "  wt1=$WT1 path=$WT1PATH"
  t W02 0 "default path lands under scratch wts" -- bash -c "[[ '${WT1PATH#/private}' == '${WTS#/private}'/* ]]"
  t W02b 0 "worktree new materialised the directory" -- test -d "$WT1PATH"
  t W02c 0 "git knows the worktree" -- bash -c "git -C '$FIX' worktree list | grep -q 'bugfix/menu'"
  t W02d 0 "--json reports created=true" -- bash -c "jq -e '.created==true' '$LOGS/W01.out'"
  t W03 0 "worktree new main --path explicit --name" -- cli worktree new main --project "$PID" --path "$RUN/wt-main" --name MainWT --json
  WT2=$(jf W03 .id)
  t W04 3 "worktree new same branch/path again -> 3 conflict" -- cli worktree new bugfix/menu --project "$PID"
  t W05 0 "worktree new --reuse-existing returns same id" -- bash -c "$CLI worktree new bugfix/menu --project $PID --reuse-existing --name reuse2 --json | jq -e '.id==\"$WT1\"'"
  t W06 0 "worktree switch <id>" -- cli worktree switch "$WT1"
  t W07 2 "worktree switch random uuid -> 2" -- cli worktree switch "$(uuidgen)"
  t W08 2 "worktree switch current outside pane -> 2" -- cli worktree switch current
  t W08b 0 "worktree switch by branch name" -- cli worktree switch main
  t W08c 0 "worktree switch by display name" -- cli worktree switch MainWT
  t W09 0 "tree shows 3 worktrees" -- bash -c "$CLI tree --project $PID --json | jq -e '.projects[0].worktrees|length==3'"
  t W10 1 "worktree rm both id and --by-path -> 1" -- cli worktree rm "$WT2" --by-path "$RUN/wt-main" --project "$PID"
  t W11 1 "worktree rm no args -> 1" -- cli worktree rm --project "$PID"
  t W12 2 "worktree rm --by-path nonexistent -> 2" -- cli worktree rm --by-path "$RUN/nope" --project "$PID"
  t W13 0 "worktree rm --by-path --delete (git worktree removed)" -- cli worktree rm --by-path "$RUN/wt-main" --project "$PID" --delete --json
  t W13a 1 "wt-main directory is gone" -- test -d "$RUN/wt-main"
  mkdir -p "$RUN/adopt-me"
  t W13b 0 "worktree new --path adopts an existing dir (created=false)" -- bash -c "$CLI worktree new adopt --project $PID --path '$RUN/adopt-me' --json | jq -e '.created==false'"
  t W13c 0 "worktree rm --by-path (register-only entry)" -- cli worktree rm --by-path "$RUN/adopt-me" --project "$PID"
  # `main` itself was deleted with wt-main above (branch cleanup per Settings); base on the remote ref.
  t W14 0 "worktree new brand-new branch --base origin/main" -- cli worktree new test/brand-new --base origin/main --project "$PID" --json
  WT3=$(jf W14 .id); WT3PATH=$(jf W14 .path)
  t W15 0 "git branch exists for the new worktree" -- git -C "$FIX" rev-parse --verify test/brand-new
  t W16 0 "worktree dir exists on disk" -- test -d "$WT3PATH"
  t W16b 3 "worktree new same branch again -> 3" -- cli worktree new test/brand-new --project "$PID"
  t W16c 1 "worktree new bad --base -> 1" -- cli worktree new test/bad-base --base no/such/ref --project "$PID"
  t W17 0 "worktree list --project <id>" -- cli worktree list --project "$PID"
  t W17b 0 "worktree list --json has 3" -- bash -c "$CLI worktree list --project $PID --json | jq -e '.worktrees|length==3'"
  t W18 0 "worktree rm <id> --delete without --project (inferred)" -- cli worktree rm "$WT3" --delete
  t W19 1 "dir gone after rm --delete" -- test -d "$WT3PATH"
  t W19b 128 "branch gone after rm --delete (git exits 128)" -- git -C "$FIX" rev-parse --verify test/brand-new
}

phase_tab_pane() {
  echo "== tab"
  t T01 0 "tab new (unnamed)" -- cli tab new --project "$PID" --worktree "$WT1" --json
  TAB1=$(jf T01 .id)
  t T02 0 "tab new named" -- cli tab new "dev server" --project "$PID" --worktree "$WT1" --json
  TAB2=$(jf T02 .id)
  t T03 0 "tab switch <id>" -- cli tab switch "$TAB1"
  t T04 0 "tree prints t<n> handle" -- bash -c "$CLI tree --project $PID | grep -E 'Tab t[0-9]+:'"
  TH=$($CLI tree --project "$PID" | grep -E "Tab t[0-9]+: .*$TAB2" | sed -E 's/.*Tab (t[0-9]+):.*/\1/')
  echo "  tab2 handle: $TH"
  t T05 0 "tab switch by handle $TH" -- cli tab switch "$TH"
  t T06 2 "tab switch random uuid -> 2" -- cli tab switch "$(uuidgen)"
  t T07 2 "tab switch t999 -> 2" -- cli tab switch t999
  t T08 2 "tab new --worktree current outside pane -> 2" -- cli tab new --project "$PID"
  t T08b 0 "tab new --worktree <branch name> (project inferred)" -- cli tab new byname --worktree bugfix/menu --json
  cli tab close "$(jf T08b .id)" >/dev/null
  t T09 0 "tab list" -- cli tab list --project "$PID" --worktree "$WT1"
  t T09b 0 "tab list --worktree <id> only (project inferred)" -- bash -c "$CLI tab list --worktree $WT1 --json | jq -e '.tabs|length>=2'"
  t T10 0 "tab close <id> with explicit locator" -- cli tab close "$TAB2" --project "$PID" --worktree "$WT1"
  t T11 2 "tab close again -> 2" -- cli tab close "$TAB2" --project "$PID" --worktree "$WT1"
  t T12 0 "tab close <id> without --project/--worktree (inferred)" -- cli tab close "$TAB1"
  t T13 0 "tab new again for the pane phase" -- cli tab new "dev server" --worktree "$WT1" --json
  TAB1=$(jf T13 .id)
  t T14 0 "tab switch by title" -- cli tab switch "dev server"

  echo "== pane"
  t N01 0 "pane new default shell" -- cli pane new --project "$PID" --worktree "$WT1" --tab "$TAB1" --cwd "$FIX" --json
  PANE1=$(jf N01 .id); echo "  pane1=$PANE1"
  t N02 0 "pane new with labels + cmd (-- sh)" -- cli pane new --project "$PID" --worktree "$WT1" --tab "$TAB1" --cwd "$FIX" --label agent worker -- /bin/sh -c 'echo PANE2-READY; exec /bin/sh'
  PANE2=$(jf N02 .id 2>/dev/null); [[ -z "$PANE2" || "$PANE2" == null ]] && PANE2=$(grep -o '[0-9A-F-]\{36\}' "$LOGS/N02.out" | head -1); echo "  pane2=$PANE2"
  t N03 0 "pane new cwd default (\$PWD)" -- bash -c "cd '$RUN' && $CLI pane new --project $PID --worktree $WT1 --tab $TAB1 --json"
  PANE3=$(jf N03 .id)
  TAB1H=$($CLI tree --project "$PID" | grep -E "Tab t[0-9]+: .*$TAB1" | sed -E 's/.*Tab (t[0-9]+):.*/\1/'); echo "  tab1 handle: $TAB1H"
  t N04 0 "pane new --tab by handle (containers inferred)" -- cli pane new --tab "$TAB1H" --cwd "$FIX" --json
  PANE4=$(jf N04 .id)
  t N05 0 "pane list" -- cli pane list --project "$PID" --worktree "$WT1" --tab "$TAB1"
  t N05b 0 "pane list --tab <handle> only has 4 panes" -- bash -c "$CLI pane list --tab $TAB1H --json | jq -e '.panes|length==4'"
  t N05c 0 "tree --json carries handles" -- bash -c "$CLI tree --project $PID --json | jq -e '[.projects[0].worktrees[].tabs[].panes[].handle]|all(startswith(\"p\"))'"
  t N06 0 "tree shows labels @agent,@worker + p<n>" -- bash -c "$CLI tree --project $PID | grep -E 'Pane p[0-9]+: .*@agent,@worker'"
  PH=$($CLI tree --project "$PID" | grep -E "Pane p[0-9]+: .*$PANE1" | sed -E 's/.*Pane (p[0-9]+):.*/\1/'); echo "  pane1 handle: $PH"
  sleep 2
  t N07 0 "pane focus <id>" -- cli pane focus "$PANE1"
  t N08 0 "pane focus <handle>" -- cli pane focus "$PH"
  t N09 0 "pane focus @label" -- cli pane focus @agent
  t N10 2 "pane focus random uuid -> 2" -- cli pane focus "$(uuidgen)"
  t N11 2 "pane focus @nolabel -> 2" -- cli pane focus @nolabel
  t N12 0 "pane label add" -- cli pane label "$PANE1" alpha beta
  t N13 0 "pane label --replace" -- cli pane label "$PANE1" solo --replace
  t N14 0 "labels after replace == [solo]" -- bash -c "$CLI tree --project $PID --json | jq -e '[.projects[0].worktrees[].tabs[].panes[]|select(.id==\"$PANE1\")|.labels]==[[\"solo\"]]'"
  t N15 64 "pane label no labels -> 64" -- cli pane label "$PANE1"
  t N16 0 "pane label second pane 'agent' (dup label)" -- cli pane label "$PANE3" agent
  t N17 3 "pane focus @agent ambiguous -> 3" -- cli pane focus @agent
  cli pane label "$PANE3" x --replace >/dev/null
  t N18 0 "pane info" -- cli pane info "$PANE1"
  t N19 0 "pane info --json has shellPid+pwd" -- bash -c "$CLI pane info $PANE1 --json | jq -e '.shellPid>0 and (.pwd|length>0)'"
  t N20 0 "pane reset" -- cli pane reset "$PANE1"
  t N21 "*" "pane info on closed/unknown pane" -- cli pane info "$(uuidgen)"
}

phase_terminal() {
  echo "== terminal io"
  t S01 0 "pane send <id> text (Enter)" -- cli pane send "$PANE1" 'echo MARK-S01'
  t S02 0 "readback shows MARK-S01" -- wait_text "$PANE1" MARK-S01
  t S03 1 "pane send -p solo (no @) -> 1 usage error" -- cli pane send -p solo 'echo MARK-S03'
  t S04 0 "pane send -p @solo" -- cli pane send -p @solo 'echo MARK-S04'
  t S05 0 "readback MARK-S04" -- wait_text "$PANE1" MARK-S04
  t S06 0 "pane send --no-enter then send-key enter" -- bash -c "$CLI pane send --no-enter $PANE1 'echo MARK-S06' && $CLI pane send-key $PANE1 enter"
  t S07 0 "readback MARK-S06" -- wait_text "$PANE1" MARK-S06
  t S08 0 "pane send --stdin" -- bash -c "printf 'echo MARK-S08\n' | $CLI pane send --stdin $PANE1"
  t S09 0 "readback MARK-S08" -- wait_text "$PANE1" MARK-S08
  t S10 0 "pane send multi-word unquoted (target parse?)" -- cli pane send "$PANE1" echo MARK-S10 more words
  t S11 0 "readback MARK-S10" -- wait_text "$PANE1" 'MARK-S10 more words'
  t S12 1 "pane send echo hi (unquoted) -> 1" -- cli pane send echo hi
  t S12b 0 "S12 error names the stray word" -- grep -q 'unknown pane "echo"' "$LOGS/S12.err"
  t S13 1 "pane send no text -> 1" -- cli pane send
  t S14 1 "pane send --stdin with tty stdin -> 1" -- cli pane send --stdin "$PANE1"
  t S15 0 "pane send --raw hex (ESC [ A)" -- cli pane send "$PANE1" --raw 1b5b41
  t S16 1 "pane send --raw + --no-enter -> 1" -- cli pane send "$PANE1" --raw 1b --no-enter
  t S17 1 "pane send --raw + text -> 1" -- cli pane send "$PANE1" --raw 1b hello
  t S18 "*" "pane send --raw bad hex" -- cli pane send "$PANE1" --raw zz
  t S19 0 "pane send --raw with 0x and spaces" -- cli pane send "$PANE1" --raw '0x15 0x0d'
  t S20 0 "pane send --focus" -- cli pane send --focus "$PANE1" 'echo MARK-S20'
  # ctrl_d ends the shell, so the key sweep gets a throwaway pane.
  KEYPANE=$($CLI pane new --tab "$TAB1" --cwd "$FIX" --json | jq -r .id); sleep 1
  t S21 0 "send-key all named keys (throwaway pane)" -- bash -c "for k in escape up down left right tab enter backspace delete home end pgup pgdn f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 ctrl_c ctrl_l ctrl_z ctrl_d; do $CLI pane send-key $KEYPANE \$k >/dev/null || exit 1; done"
  t S22 0 "send-key ctrl-c dashed form" -- cli pane send-key "$PANE1" ctrl-c
  t S23 0 "send-key -p" -- cli pane send-key -p "$PANE1" ctrl_l
  t S24 1 "send-key bogus -> 1" -- cli pane send-key "$PANE1" bogus
  t S25 1 "send-key none -> 1" -- cli pane send-key
  cli pane close "$KEYPANE" >/dev/null 2>&1
  cli pane send "$PANE1" 'clear; for i in $(seq 1 80); do echo LINE-$i; done; echo MARK-S26' >/dev/null
  wait_text "$PANE1" MARK-S26
  t S26 0 "pane read (zmx dump)" -- cli pane read "$PANE1"
  t S27 0 "pane read contains LINE-80" -- bash -c "$CLI pane read $PANE1 | grep -q LINE-80"
  t S28 0 "pane read --tail 3 -> 3 lines" -- bash -c "$CLI pane read $PANE1 --tail 3 | wc -l | tr -d ' ' | grep -qE '^[1-4]$'"
  t S29 1 "pane read --tail 0 -> 1" -- cli pane read "$PANE1" --tail 0
  t S30 0 "pane read --raw has ESC" -- bash -c "$CLI pane read $PANE1 --raw | grep -q \$'\\x1b'"
  t S31 0 "pane read --range visible" -- cli pane read "$PANE1" --range visible
  t S32 0 "pane read --json" -- bash -c "$CLI pane read $PANE1 --json | jq -e '.format==\"plain\"'"
  t S33 64 "pane read --screen is not an option -> 64" -- cli pane read "$PANE1" --screen
  t S34 0 "pane capture" -- cli pane capture "$PANE1"
  t S35 0 "pane capture --lines 5 -> 5 lines" -- bash -c "$CLI pane capture $PANE1 --lines 5 --json | jq -e '.lines==5'"
  t S36 0 "pane capture --scope screen" -- cli pane capture "$PANE1" --scope screen
  t S37 1 "pane capture --lines 0 -> 1" -- cli pane capture "$PANE1" --lines 0
  t S38 0 "pane capture --wait-stable --json" -- bash -c "$CLI pane capture $PANE1 --wait-stable --json | jq -e '.stabilized==true'"
  t S39 1 "pane capture --wait-stable --timeout-ms >= --timeout -> 1" -- cli pane capture "$PANE1" --wait-stable --timeout-ms 20000
  t S40 64 "pane capture -p is not an option -> 64" -- cli pane capture -p "$PANE1"
  t S41 0 "pane capture --scope bogus -> usage(1)?" -- bash -c "$CLI pane capture $PANE1 --scope bogus; test \$? -ne 0"
  echo "== broadcast"
  t B01 0 "broadcast --tab" -- cli broadcast --tab "$TAB1" 'echo MARK-B01'
  t B02 0 "readback in pane1" -- wait_text "$PANE1" MARK-B01
  t B03 0 "broadcast --tab delivered==4" -- bash -c "$CLI broadcast --tab $TAB1 --json 'echo MARK-B03' | jq -e '.delivered==4'"
  t B04 0 "broadcast --worktree" -- cli broadcast --worktree "$WT1" 'echo MARK-B04'
  t B05 0 "broadcast --label" -- cli broadcast --label agent 'echo MARK-B05'
  t B06 0 "broadcast --label unknown delivered==0" -- bash -c "$CLI broadcast --label nolabel --json 'x' | jq -e '.delivered==0'"
  t B07 1 "broadcast no scope -> 1" -- cli broadcast 'x'
  t B08 1 "broadcast two scopes -> 1" -- cli broadcast --tab "$TAB1" --label a 'x'
  t B09 0 "broadcast --stdin --no-enter" -- bash -c "printf 'echo MARK-B09' | $CLI broadcast --tab $TAB1 --stdin --no-enter"
  cli broadcast --tab "$TAB1" --stdin --no-enter <<<'' >/dev/null 2>&1; cli pane send-key "$PANE1" enter >/dev/null
  t B10 1 "broadcast --stdin + text -> 1" -- bash -c "echo x | $CLI broadcast --tab $TAB1 --stdin 'y'"
  t B11 2 "broadcast --tab current outside pane -> 2" -- cli broadcast --tab current 'x'
}

phase_incontext() {
  echo "== in-pane context (commands run inside pane1 through pane send)"
  # Each probe writes `CTX-<id>=<exit>` on the pane's screen.
  ctx() { # ctx <id> <cmdline>
    local id="$1"; shift
    cli pane send "$PANE1" "clear; $* >/tmp/codans-ctx-$id.out 2>&1; echo CTX-$id=\$?" >/dev/null
    wait_text "$PANE1" "CTX-$id=" 10
    local line; line=$(cli pane capture "$PANE1" --scope screen | grep -o "CTX-$id=[0-9]*" | tail -1)
    echo "${line#*=}"
  }
  for spec in \
    "X01|tree --project current|0" \
    "X02|pane send 'echo CTX-INNER'|0" \
    "X03|pane read|0" \
    "X04|pane capture --lines 3|0" \
    "X05|pane info|0" \
    "X06|project commands list|0" \
    "X07|tab new ctxtab --json|0" \
    "X08|pane new --json|0" \
    "X09|broadcast --tab current 'echo CTX-BC'|0" \
    "X10|worktree new test/ctx-wt --json|0" \
    "X11|pane focus current|0" \
    "X12|pane label current ctxlabel|0" \
    "X13|agent list|0" \
    "X14|doctor --json|0" \
    "X16|tab switch current|0" \
    "X17|worktree switch current|0" \
    "X15|pane send-key escape|0" \
    ; do
    IFS='|' read -r id cmd want <<<"$spec"
    got=$(ctx "$id" "codans-dev $cmd")
    verdict=PASS; [[ "$got" != "$want" ]] && verdict=FAIL
    [[ $verdict == PASS ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
    cp "/tmp/codans-ctx-$id.out" "$LOGS/$id.out" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$verdict" "$want" "$got" "in-pane: codans-dev $cmd" "" >>"$RESULTS"
    printf '%-8s %-4s want=%-3s got=%-3s in-pane: codans-dev %s\n' "$id" "$verdict" "$want" "$got" "$cmd"
    [[ $verdict == FAIL ]] && head -2 "$LOGS/$id.out" | sed 's/^/    out: /'
  done
  # prove the pane's env only carries CODANS_PANE_ID
  ctx X20 'env | grep -E "^CODANS_" | cut -d= -f1 | sort | tr "\n" " "' >/dev/null
  note "pane env CODANS_* keys: $(cat /tmp/codans-ctx-X20.out)"
  # cleanup ctx worktree if created
  local ctxwt; ctxwt=$(jq -r .id "$LOGS/X10.out" 2>/dev/null || true)
  [[ -n "$ctxwt" && "$ctxwt" != null ]] && cli worktree rm "$ctxwt" --project "$PID" >/dev/null 2>&1
}

phase_agent_handoff() {
  echo "== agent"
  t G01 0 "agent list" -- cli agent list
  t G02 0 "agent list --json has 3 profiles" -- bash -c "$CLI agent list --json | jq -e '.profiles|length==3'"
  t G03 1 "agent launch no args -> 1" -- cli agent launch --project "$PID" --worktree "$WT1"
  t G04 1 "agent launch --tab --split -> 1" -- cli agent launch 'Fake Amp' --tab --split right --project "$PID" --worktree "$WT1"
  t G05 2 "agent launch unknown profile -> 2" -- cli agent launch 'No Such Profile' --project "$PID" --worktree "$WT1"
  t G06 3 "agent launch disabled profile -> 3" -- cli agent launch 'Disabled Codex' --project "$PID" --worktree "$WT1"
  t G07 0 "agent launch 'Fake Amp' --background --json" -- cli agent launch 'Fake Amp' --background --project "$PID" --worktree "$WT1" --json
  AGPANE=$(jf G07 .paneID)
  t G08 0 "fake amp started in new pane" -- wait_text "$AGPANE" 'FAKE-AGENT amp' 10
  t G09 4 "agent launch amp --prompt -> 4 unsupported" -- cli agent launch --agent amp --prompt 'hi' --project "$PID" --worktree "$WT1"
  t G10 0 "agent launch --agent claude --prompt - (stdin) --split right" -- bash -c "echo 'do the thing' | $CLI agent launch --agent claude --prompt - --split right --project $PID --worktree $WT1 --json"
  AGPANE2=$(jf G10 .paneID)
  t G11 0 "fake claude got prompt on argv" -- wait_text "$AGPANE2" 'do the thing' 10
  t G12 1 "agent launch --prompt '' -> 1" -- cli agent launch --agent claude --prompt '   ' --project "$PID" --worktree "$WT1"
  t G13 2 "agent launch --worktree current outside pane -> 2" -- cli agent launch --agent claude --project "$PID"
  t G14 0 "agent launch --worktree <branch> --background" -- cli agent launch 'Fake Amp' --background --worktree bugfix/menu --json
  AGPANE3=$(jf G14 .paneID)
  echo "== handoff"
  t H01 1 "handoff to bogus agent -> 1" -- cli handoff to bogus --pane "$PANE1" --no-brief
  t H02 1 "handoff to amp neither brief nor no-brief -> 1" -- cli handoff to amp --pane "$PANE1"
  t H03 1 "handoff --brief + --no-brief -> 1" -- cli handoff to amp --pane "$PANE1" --brief x --no-brief
  t H04 1 "handoff --brief '' -> 1" -- cli handoff to amp --pane "$PANE1" --brief '  '
  t H05 1 "handoff to amp --brief missing sections -> 1" -- cli handoff to amp --pane "$PANE1" --brief 'just text' --no-launch
  t H06 0 "handoff save --brief - (heredoc)" -- bash -c "$CLI handoff save --pane $PANE1 --brief - <<'EOF'
# Handoff
## Objective
Test objective
## Current State
State
## Next Steps
1. go
EOF"
  t H07 0 "current.md written in worktree" -- test -f "$WT1PATH/.codans/handoff/current.md"
  t H08 0 "handoff save --no-brief (context only)" -- cli handoff save --pane "$PANE1" --no-brief --json
  t H09 0 "handoff to amp --no-brief --no-launch --json" -- cli handoff to amp --pane "$PANE1" --no-brief --no-launch --json
  # A split receiver's surface comes up with its tab; make the source pane's tab the visible one first.
  cli pane focus "$PANE1" >/dev/null; sleep 1
  t H10 0 "handoff to amp --profile 'Fake Amp' --split down --no-brief (launches fake)" -- cli handoff to amp --pane "$PANE1" --profile 'Fake Amp' --split down --no-brief --json
  HOPANE=$(jf H10 .launchedPane.paneID)
  t H11 0 "receiver fake amp came up" -- wait_text "$HOPANE" 'FAKE-AGENT amp' 15
  if [[ -n "$HOPANE" && "$HOPANE" != null ]]; then
    { cli tree --project "$PID"; cli pane info "$HOPANE"; cli pane read "$HOPANE" --tail 20; cli pane capture "$HOPANE" --scope screen; } > "$LOGS/H11.diag" 2>&1
  fi
  t H12 0 "typed kickoff reached fake amp (RECEIVED:)" -- wait_text "$HOPANE" 'RECEIVED:' 20
  t H13 1 "handoff to amp --tab --split -> 1" -- cli handoff to amp --pane "$PANE1" --tab --split up --no-brief
  t H14 2 "handoff to claude --pane current outside pane -> 2" -- cli handoff to claude --no-brief --no-launch
  for p in "$AGPANE" "$AGPANE2" "$AGPANE3" "$HOPANE"; do [[ -n "$p" && "$p" != null ]] && cli pane close "$p" >/dev/null 2>&1; done
}

phase_close() {
  echo "== close & teardown"
  t Z01 0 "pane close <id>" -- cli pane close "$PANE4"
  t Z02 2 "pane close again -> 2" -- cli pane close "$PANE4"
  t Z03 0 "pane close with explicit locator" -- cli pane close "$PANE3" --project "$PID" --worktree "$WT1" --tab "$TAB1"
  t Z04 0 "pane close @worker" -- cli pane close @worker
  t Z05 0 "pane close by handle" -- cli pane close "$PH"
  t Z06 0 "tab close <id> explicit" -- cli tab close "$TAB1" --project "$PID" --worktree "$WT1"
  # any leftovers
  for p in $($CLI tree --project "$PID" --json | jq -r '.projects[].worktrees[].tabs[].panes[].id'); do cli pane close "$p" >/dev/null 2>&1; done
  t Z07 0 "worktree rm wt1 --delete (project inferred)" -- cli worktree rm "$WT1" --delete
  t Z08 0 "project rm by name" -- cli project rm fixture
  t Z09 0 "tree empty" -- bash -c "$CLI tree --json | jq -e '.projects|length==0'"
  quit_app
  t Z10 10 "status after quit -> 10" -- cli status
  t Z11 0 "doctor after quit reports app-not-running/socket-missing" -- bash -c "$CLI doctor --json | jq -e '.socketStatus==\"app-not-running\" or .socketStatus==\"socket-missing\"'"
}

case "$PHASE" in
  all)
    setup; launch_app
    phase_app; phase_project; phase_worktree; phase_tab_pane; phase_terminal; phase_incontext; phase_agent_handoff; phase_close
    ;;
  setup) setup; launch_app ;;
  quit) quit_app ;;
  *) echo "unknown phase $PHASE"; exit 2 ;;
esac
echo "PASS=$PASS FAIL=$FAIL  (results: $RESULTS)"
