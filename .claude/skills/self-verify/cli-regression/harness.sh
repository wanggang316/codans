#!/usr/bin/env bash
# Black-box regression of every `codans` verb against an isolated Debug
# instance: private socket, scratch config directory, fixture repo, fake
# agents. Never touches the default dev / release sockets or catalogs.
#
# Usage: harness.sh <Debug Codans.app path> [all|setup|quit]
#
# `tab` verbs drive one Tab and its session, `pane` verbs the layout; ids
# come from the harness's own `tab new` / `pane split` output.
#   all    launch the instance, run every phase, quit it (default)
#   setup  launch the instance and leave it running (manual probing)
#   quit   stop a running instance
#
# Work files land in $CODANS_CLI_REGRESSION_DIR (default: a fresh mktemp dir);
# results.tsv there lists every case with wanted / got exit codes.
set -uo pipefail

APP="$1"
PHASE="${2:-all}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
SCRATCH="${CODANS_CLI_REGRESSION_DIR:-$(mktemp -d -t codans-cli-regression)}"
mkdir -p "$SCRATCH"
CLI="$APP/Contents/Resources/bin/codans-dev"
# AF_UNIX paths are capped near 104 bytes, so the socket stays out of $SCRATCH.
# CODANS_CLI_REGRESSION_SOCK / _CACHE override them so two harness runs
# (or another isolated instance) never share a socket or daemons.
SOCK="${CODANS_CLI_REGRESSION_SOCK:-/tmp/codans-t-$(id -u).sock}"
# The cache dir holds one zmx socket per pane, so it stays short too. Without
# it the instance shares the dev cache and its launch sweep kills the dev
# app's pane sessions.
CACHE="${CODANS_CLI_REGRESSION_CACHE:-/tmp/codans-t-cache-$(id -u)}"
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
jf() { jq -r ".data | $2" "$LOGS/$1.out"; }
# note a finding (not a pass/fail)
note() { printf 'NOTE\t%s\n' "$*" >>"$RESULTS"; echo "  note: $*"; }

cli() { "$CLI" "$@"; }

# ---------- environment ----------
# Scrub the release pane's own context so the dev CLI and the test app
# never see Gump's socket / pane / tab / content ids.
unset CODANS_PANE_ID CODANS_TAB_ID CODANS_CONTENT_ID CODANS_CLI CODANS_WORKTREE_PATH CODANS_ROOT_PATH \
  CODANS_RUNTIME_DIR ZMX_DIR ZMX_SESSION TERM_PROGRAM TERM_PROGRAM_VERSION
# A state root would win over CODANS_CONFIG_DIR; unset, state follows it.
unset CODANS_STATE_DIR
export CODANS_SOCKET_PATH="$SOCK"
export CODANS_CONFIG_DIR="$CONF"
export CODANS_CACHE_DIR="$CACHE"

setup() {
  : >"$RESULTS"
  rm -rf "$CONF" "$RUN"; mkdir -p "$CONF" "$RUN" "$WTS" "$FAKEBIN" "$LOGS"
  bash "$REPO_ROOT/.claude/skills/self-verify/fixtures/restore-repo.sh" "$FIX" >/dev/null
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
    if cli doctor --json 2>/dev/null | jq -e '.data | .socketStatus == "ok"' >/dev/null 2>&1; then break; fi
    sleep 0.2
  done
  cli status
  local up; up=$(cli status --json | jq -r '.data | .uptimeSeconds')
  awk -v u="$up" 'BEGIN{ if (u+0 > 30) { print "uptime too high: " u; exit 1 } }' || { echo "REFUSING: socket answered by an older instance"; exit 1; }
  # sanity: the socket is held by our pid
  lsof -p "$APP_PID" 2>/dev/null | grep -q "$SOCK" || echo "warning: could not confirm socket ownership via lsof"
}

quit_app() {
  local pid; pid=$(pgrep -f "$APP/Contents/MacOS/Codans" | head -1)
  [[ -n "$pid" ]] && kill -TERM "$pid" && sleep 2
  pgrep -f "$APP/Contents/MacOS/Codans" >/dev/null && kill -KILL "$pid"
  # zmx daemons of tabs the run did not close hold files in the cache dir.
  local holders; holders=$(lsof -t +D "$CACHE" 2>/dev/null | sort -u)
  [[ -n "$holders" ]] && kill -TERM $holders 2>/dev/null
  rm -rf "$CACHE"
  rm -f "$SOCK"
  echo "quit test app"
}

wait_text() { # wait_text <tab> <needle> [secs]
  local tab="$1" needle="$2" secs="${3:-10}"
  for _ in $(seq 1 $((secs*5))); do
    if cli tab capture "$tab" --scope screen 2>/dev/null | grep -q -- "$needle"; then return 0; fi
    if cli tab read "$tab" 2>/dev/null | grep -q -- "$needle"; then return 0; fi
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
  t A04 0 "doctor --json has socketStatus ok" -- bash -c "$CLI doctor --json | jq -e '.data | .socketStatus==\"ok\" and .client==\"codans-dev\"'"
  t A05 0 "--version" -- cli --version
  t A06 0 "--help" -- cli --help
  t A07 0 "launch while running (idempotent)" -- cli launch --wait 2
  t A08 10 "status --socket /nonexistent -> 10" -- cli status --socket /tmp/codans-nope-$$.sock
  t A09 0 "doctor --socket nonexistent reports socket-missing" -- bash -c "$CLI doctor --socket /tmp/codans-nope-$$.sock --json | jq -e '.data | .socketStatus==\"socket-missing\"'"
  t A10 14 "status --socket <regular file> -> 14" -- cli status --socket "$RESULTS"
  t A11 0 "help-json prints the subcommand tree" -- bash -c "$CLI help-json | jq -e '.subcommands|map(.name)|index(\"open\")'"
  t A12 0 "open --help" -- cli open --help
  t A16 "*" "open --in no-such-editor (strict, must fail, no side effect)" -- bash -c "$CLI open --in no-such-editor '$RUN'; test \$? -ne 0"
  t A13 64 "unknown subcommand -> 64 (EX_USAGE)" -- cli frobnicate
  t A15 0 "completion script zsh" -- cli --generate-completion-script zsh
  t A17 0 "status --json is an envelope with schemaVersion + data" -- bash -c "$CLI status --json | jq -e '.schemaVersion==\"codans.cli.status.v1\" and (.data.server|length>0) and (.error==null)'"
  t A18 0 "--json error is an envelope on stdout with a stable code (exit 2)" -- bash -c "out=\$($CLI pane focus \$(uuidgen) --json); rc=\$?; test \$rc -eq 2 && jq -e '.error.code==\"NOT_FOUND\" and .error.details.kind==\"pane\" and (.data==null)' <<<\"\$out\""
  t A18b 0 "--json NO_CURRENT_CONTEXT outside a pane" -- bash -c "$CLI tree --project current --json | jq -e '.error.code==\"NO_CURRENT_CONTEXT\"'"
  echo "== skill"
  mkdir -p "$RUN/home/.claude" "$RUN/home/.codex"
  t K01 0 "skill path codans-cli points into the bundle" -- bash -c "p=\$($CLI skill path codans-cli) && test -f \"\$p/SKILL.md\""
  t K02 0 "skill list --json lists codans-cli with detected targets" -- bash -c "HOME='$RUN/home' $CLI skill list --json | jq -e '.data.skills|map(select(.id==\"codans-cli\"))|.[0].targets|map(.target)==[\"claude\",\"codex\"] and all(.status==\"missing\")'"
  t K03 0 "skill install --target claude links the skill" -- bash -c "HOME='$RUN/home' $CLI skill install codans-cli --target claude --json | jq -e '.data.installed|length==1' && test -L '$RUN/home/.claude/skills/codans-cli' && test -f '$RUN/home/.claude/skills/codans-cli/SKILL.md'"
  t K03b 0 "skill list reports installed / missing per target" -- bash -c "HOME='$RUN/home' $CLI skill list --json | jq -e '[.data.skills[]|select(.id==\"codans-cli\")|.targets[]|.status]==[\"installed\",\"missing\"]'"
  t K04 0 "skill install again is a no-op" -- bash -c "HOME='$RUN/home' $CLI skill install codans-cli --target claude --json | jq -e '.data.installed==[] and (.data.skipped|length==1)'"
  t K05 2 "skill install unknown id -> 2" -- env HOME="$RUN/home" "$CLI" skill install no-such-skill --target claude
  mkdir -p "$RUN/home/.codex/skills/codans-cli"
  t K06 3 "skill install over a foreign directory -> 3 conflict" -- env HOME="$RUN/home" "$CLI" skill install codans-cli --target codex
  t K06b 0 "skill install --force replaces it" -- bash -c "HOME='$RUN/home' $CLI skill install codans-cli --target codex --force >/dev/null && test -L '$RUN/home/.codex/skills/codans-cli'"
  t K07 0 "skill uninstall removes the links" -- bash -c "HOME='$RUN/home' $CLI skill uninstall codans-cli --json | jq -e '.data.removed|length==2' && ! test -e '$RUN/home/.claude/skills/codans-cli'"
  mkdir -p "$RUN/proj/.git" "$RUN/proj/.claude"
  t K08 0 "skill install --scope project links under the repo" -- bash -c "cd '$RUN/proj' && HOME='$RUN/home' $CLI skill install --scope project --target claude >/dev/null && test -L '$RUN/proj/.claude/skills/codans-cli'"
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
  # The git root is what git reports for the fixture: under $TMPDIR that is
  # the /private/var form, while rootPath keeps the /var form.
  FIXROOT=$(git -C "$FIX" rev-parse --show-toplevel)
  t P06b 0 "project add detected the git root" -- bash -c "jq -e '.data | .gitRoot==\"$FIXROOT\"' '$LOGS/P01.out'"
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
  t P14 0 "project list --json has 1 project" -- bash -c "$CLI project list --json | jq -e '.data | .projects|length==1'"
  t P15 2 "tree --project unknown-name -> 2" -- cli tree --project no-such-project
  t P16 0 "project show <id>" -- cli project show "$PID"
  t P16b 0 "project show --json carries gitRoot + worktreeCount" -- bash -c "$CLI project show $PID --json | jq -e '.data | .gitRoot==\"$FIXROOT\" and .worktreeCount>=1 and (.id|type==\"string\")'"
  t P16c 2 "project show random uuid -> 2" -- cli project show "$(uuidgen)"
  t P17 0 "project rename <id> Renamed" -- cli project rename "$PID" Renamed --json
  t P17b 0 "tree --project Renamed resolves the new name" -- cli tree --project Renamed
  t P17c 0 "project rename '' clears the override" -- bash -c "$CLI project rename $PID '' --json | jq -e '.data | .name==\"fixture\"'"
  echo "== project commands"
  t C01 0 "commands list (empty)" -- cli project commands list --project "$PID"
  t C02 0 "commands add" -- cli project commands add --project "$PID" --command 'echo hello' --name Hello --json
  CID=$(jf C02 .id)
  t C03 1 "commands add empty command -> 1" -- cli project commands add --project "$PID" --command ''
  t C04 0 "commands list shows one" -- bash -c "$CLI project commands list --project $PID --json | jq -e '.data | .scripts|length==1'"
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
  t W02d 0 "--json reports created=true" -- bash -c "jq -e '.data | .created==true' '$LOGS/W01.out'"
  t W03 0 "worktree new main --path explicit --name" -- cli worktree new main --project "$PID" --path "$RUN/wt-main" --name MainWT --json
  WT2=$(jf W03 .id)
  t W04 3 "worktree new same branch/path again -> 3 conflict" -- cli worktree new bugfix/menu --project "$PID"
  t W05 0 "worktree new --reuse-existing returns same id" -- bash -c "$CLI worktree new bugfix/menu --project $PID --reuse-existing --name reuse2 --json | jq -e '.data | .id==\"$WT1\"'"
  t W06 0 "worktree switch <id>" -- cli worktree switch "$WT1"
  t W07 2 "worktree switch random uuid -> 2" -- cli worktree switch "$(uuidgen)"
  t W08 2 "worktree switch current outside pane -> 2" -- cli worktree switch current
  t W08b 0 "worktree switch by branch name" -- cli worktree switch main
  t W08c 0 "worktree switch by display name" -- cli worktree switch MainWT
  t W09 0 "tree shows 3 worktrees" -- bash -c "$CLI tree --project $PID --json | jq -e '.data | .projects[0].worktrees|length==3'"
  t W10 1 "worktree rm both id and --by-path -> 1" -- cli worktree rm "$WT2" --by-path "$RUN/wt-main" --project "$PID"
  t W11 1 "worktree rm no args -> 1" -- cli worktree rm --project "$PID"
  t W12 2 "worktree rm --by-path nonexistent -> 2" -- cli worktree rm --by-path "$RUN/nope" --project "$PID"
  t W13 0 "worktree rm --by-path --delete (git worktree removed)" -- cli worktree rm --by-path "$RUN/wt-main" --project "$PID" --delete --json
  t W13a 1 "wt-main directory is gone" -- test -d "$RUN/wt-main"
  mkdir -p "$RUN/adopt-me"
  t W13b 0 "worktree new --path adopts an existing dir (created=false)" -- bash -c "$CLI worktree new adopt --project $PID --path '$RUN/adopt-me' --json | jq -e '.data | .created==false'"
  t W13c 0 "worktree rm --by-path (register-only entry)" -- cli worktree rm --by-path "$RUN/adopt-me" --project "$PID"
  # `main` itself was deleted with wt-main above (branch cleanup per Settings); base on the remote ref.
  t W14 0 "worktree new brand-new branch --base origin/main" -- cli worktree new test/brand-new --base origin/main --project "$PID" --json
  WT3=$(jf W14 .id); WT3PATH=$(jf W14 .path)
  t W15 0 "git branch exists for the new worktree" -- git -C "$FIX" rev-parse --verify test/brand-new
  t W16 0 "worktree dir exists on disk" -- test -d "$WT3PATH"
  t W16b 3 "worktree new same branch again -> 3" -- cli worktree new test/brand-new --project "$PID"
  t W16c 1 "worktree new bad --base -> 1" -- cli worktree new test/bad-base --base no/such/ref --project "$PID"
  t W17 0 "worktree list --project <id>" -- cli worktree list --project "$PID"
  t W17b 0 "worktree list --json has 3" -- bash -c "$CLI worktree list --project $PID --json | jq -e '.data | .worktrees|length==3'"
  t W18 0 "worktree rm <id> --delete without --project (inferred)" -- cli worktree rm "$WT3" --delete
  t W19 1 "dir gone after rm --delete" -- test -d "$WT3PATH"
  t W19b 128 "branch gone after rm --delete (git exits 128)" -- git -C "$FIX" rev-parse --verify test/brand-new
  t W20 0 "worktree show <id> --json has branch + projectName" -- bash -c "$CLI worktree show $WT1 --json | jq -e '.data | .branch==\"bugfix/menu\" and .projectName==\"fixture\" and (.projectID|type==\"string\")'"
  t W20b 0 "worktree show by branch (text)" -- cli worktree show bugfix/menu
  t W21 0 "worktree rename <id> Menu (project inferred)" -- cli worktree rename "$WT1" Menu --json
  t W21b 0 "worktree switch by the new name" -- cli worktree switch Menu
  t W21c 0 "worktree show reports the new name, same path" -- bash -c "$CLI worktree show $WT1 --json | jq -e '.data | .name==\"Menu\" and .path==\"$WT1PATH\"'"
  t W22 1 "worktree rename blank -> 1" -- cli worktree rename "$WT1" '   '
  git -C "$FIX" worktree add -q "$RUN/stale" -b test/stale 2>/dev/null; rm -rf "$RUN/stale"
  t W23 0 "worktree prune reports the stale registration" -- bash -c "$CLI worktree prune --project $PID --json | jq -e '.data | .pruned==1'"
  t W23b 0 "git no longer lists the stale worktree" -- bash -c "! git -C '$FIX' worktree list | grep -q '$RUN/stale'"
  t W24 2 "worktree prune --project current outside pane -> 2" -- cli worktree prune
  t W25 0 "worktree switch by absolute path" -- cli worktree switch "$WT1PATH"
  t W25b 0 "worktree show by a subdirectory path" -- bash -c "mkdir -p '$WT1PATH/sub' && $CLI worktree show '$WT1PATH/sub' --json | jq -e '.data.id==\"$WT1\"'"
  t W25c 0 "worktree show by a relative path (resolved against \$PWD)" -- bash -c "cd '$WT1PATH/..' && $CLI worktree show ./menu --json | jq -e '.data.id==\"$WT1\"'"
  t W25d 2 "worktree show unregistered path -> 2" -- cli worktree show /tmp
}

phase_tab() {
  echo "== tab"
  t T01 0 "tab new --project --worktree --cwd (focused pane, or the worktree's first)" -- cli tab new --project "$PID" --worktree "$WT1" --cwd "$FIX" --json
  TAB1=$(jf T01 .id); TAB1C=$(jf T01 .contentID); P1=$(jf T01 .paneID)
  echo "  tab1=$TAB1 content=$TAB1C pane=$P1"
  t T01b 0 "tab new --json carries handle t<n>, pane and content ids" -- bash -c "jq -e '.data | (.handle|startswith(\"t\")) and (.paneID|length==36) and (.contentID|length==36)' '$LOGS/T01.out'"
  t T01c 0 "tab new prints only the new tab id in text mode" -- bash -c "id=\$($CLI tab new --pane $P1 --cwd '$FIX') && [[ \$id =~ ^[0-9A-F-]{36}\$ ]] && $CLI tab close \$id >/dev/null"
  t T01d 0 "tab new outside a tab without --project/--worktree uses the shown worktree" -- bash -c "id=\$($CLI tab new --cwd '$FIX') && $CLI tab close \$id >/dev/null"
  t T02 0 "tab new --pane <pane> --name --label" -- cli tab new --pane "$P1" --name "dev server" --cwd "$FIX" --label agent worker --json
  TAB2=$(jf T02 .id); TAB2C=$(jf T02 .contentID)
  t T02b 0 "tab new --pane put the tab on that pane's strip" -- bash -c "jq -e '.data.paneID==\"$P1\"' '$LOGS/T02.out'"
  t T03 0 "tab focus <id>" -- cli tab focus "$TAB1"
  t T04 0 "tree prints Pane p<n> and Tab t<n> lines" -- bash -c "$CLI tree --project $PID | grep -E 'Pane p[0-9]+:' && $CLI tree --project $PID | grep -E 'Tab t[0-9]+: .*content [0-9A-F-]{36}'"
  TH=$($CLI tree --project "$PID" | grep -E "Tab t[0-9]+: .*$TAB2" | sed -E 's/.*Tab (t[0-9]+):.*/\1/')
  PH=$($CLI tree --project "$PID" | grep -E "Pane p[0-9]+: .*$P1" | sed -E 's/.*Pane (p[0-9]+):.*/\1/')
  echo "  tab2 handle: $TH  pane1 handle: $PH"
  t T04b 0 "tree --json nests worktree -> panes -> tabs with handles and focus" -- bash -c "$CLI tree --project $PID --json | jq -e '.data.projects[0].worktrees[] | select(.id==\"$WT1\") | (.focusedPaneID|length==36) and (.panes|all((.handle|startswith(\"p\")) and (.tabs|all((.handle|startswith(\"t\")) and (.contentID|length==36)))))'"
  t T05 0 "tab focus by handle $TH" -- cli tab focus "$TH"
  t T06 2 "tab focus random uuid -> 2" -- cli tab focus "$(uuidgen)"
  t T07 2 "tab focus t999 -> 2" -- cli tab focus t999
  t T08 2 "tab new --project only, worktree current outside a tab -> 2" -- cli tab new --project "$PID"
  t T08b 0 "tab new --worktree <branch name> (project inferred)" -- cli tab new --name byname --worktree bugfix/menu --cwd "$FIX" --json
  cli tab close "$(jf T08b .id)" >/dev/null
  t T09 0 "tab list" -- cli tab list --project "$PID" --worktree "$WT1"
  t T09b 0 "tab list --pane <handle> lists that strip" -- bash -c "$CLI tab list --pane $PH --json | jq -e '.data.tabs | (map(.id)|index(\"$TAB1\")) and (map(.id)|index(\"$TAB2\")) and all(.paneID==\"$P1\")'"
  t T09c 0 "tab list --pane <tab id> means that tab's pane" -- bash -c "$CLI tab list --pane $TAB2 --json | jq -e '.data.tabs|all(.paneID==\"$P1\")'"
  t T10 0 "tab show --json: handle, pane, content, title, labels" -- bash -c "$CLI tab show $TAB2 --json | jq -e '.data | (.handle==\"$TH\") and .paneID==\"$P1\" and .contentID==\"$TAB2C\" and .title==\"dev server\" and .labels==[\"agent\",\"worker\"] and .worktreeID==\"$WT1\"'"
  t T10b 0 "tab show <content id> names its tab" -- bash -c "$CLI tab show $TAB2C --json | jq -e '.data.id==\"$TAB2\"'"
  t T10c 0 "tab show <pane id> names the pane's selected tab" -- bash -c "sel=\$($CLI pane list --project $PID --worktree $WT1 --json | jq -r '.data.panes[]|select(.id==\"$P1\")|.selectedTabID'); $CLI tab show $P1 --json | jq -e \".data.id==\\\"\$sel\\\" and .data.isSelected\""
  t T10d 0 "tab show by title (text)" -- cli tab show "dev server"
  t T11 0 "tab rename <id> renamed-tab" -- cli tab rename "$TAB2" renamed-tab --json
  t T11b 0 "tab focus by the new title" -- cli tab focus renamed-tab
  t T12 0 "tab rename <id> (no name) clears the title" -- bash -c "$CLI tab rename $TAB2 --json | jq -e '.data | .name==null'"
  cli tab rename "$TAB2" "dev server" >/dev/null
  t T13 0 "tab label add" -- cli tab label "$TAB1" alpha beta
  t T14 0 "tab label --replace" -- cli tab label "$TAB1" solo --replace
  t T14b 0 "labels after replace == [solo]" -- bash -c "$CLI tab show $TAB1 --json | jq -e '.data.labels==[\"solo\"]'"
  t T15 64 "tab label without labels -> 64" -- cli tab label "$TAB1"
  t T16 0 "tab info --json has shellPid + pwd + all three ids" -- bash -c "$CLI tab info $TAB1 --json | jq -e '.data | .shellPid>0 and (.pwd|length>0) and .tabID==\"$TAB1\" and .contentID==\"$TAB1C\" and .paneID==\"$P1\"'"
  t T17 0 "tab reset" -- cli tab reset "$TAB1"
  t T18 2 "tab info unknown -> 2" -- cli tab info "$(uuidgen)"

  echo "== verbs at their former location"
  for spec in "pane new|tab new" "pane show $TAB1|tab show" "pane send $TAB1 hi|tab send" "pane send-key $TAB1 enter|tab send-key" \
    "pane capture $TAB1|tab capture" "pane read $TAB1|tab read" "pane info $TAB1|tab info" "pane label $TAB1 x|tab label" \
    "pane reset $TAB1|tab reset" "tab switch $TAB1|tab focus"; do
    IFS='|' read -r old new <<<"$spec"
    verb="${old%% *}-$(echo "$old" | cut -d' ' -f2)"
    t "M-$verb" 1 "$old -> 1 naming '$new'" -- bash -c "$CLI $old 2>&1 >/dev/null | grep -qF 'codans-dev $new' && exit 1"
  done
  t M-json 1 "moved verb --json: MOVED_VERB envelope on stdout" -- bash -c "out=\$($CLI pane read $TAB1 --json); rc=\$?; jq -e '.error.code==\"MOVED_VERB\" and .error.details.to==\"tab read\"' <<<\"\$out\" >/dev/null && exit \$rc; exit 99"
}

phase_pane() {
  echo "== pane"
  t N01 0 "pane split <pane> --direction down --json: new pane, tab, content" -- cli pane split "$P1" --direction down --cwd "$FIX" --json
  SP=$(jf N01 .paneID); ST=$(jf N01 .tabID); SC=$(jf N01 .contentID); echo "  split pane=$SP tab=$ST content=$SC"
  t N01b 0 "the new tab sits on the new pane" -- bash -c "$CLI tab show $ST --json | jq -e '.data | .paneID==\"$SP\" and .contentID==\"$SC\"'"
  t N02 0 "pane list --json: panes in layout order with handles, strips, focus" -- bash -c "$CLI pane list --project $PID --worktree $WT1 --json | jq -e '.data.panes | (map(.id)|index(\"$P1\")) and (map(.id)|index(\"$SP\")) and all(.handle|startswith(\"p\")) and (map(select(.isFocused))|length==1) and (map(select(.id==\"$SP\"))[0].tabIDs==[\"$ST\"])'"
  t N03 0 "pane focus <id>" -- cli pane focus "$SP"
  t N04 0 "pane focus <handle>" -- cli pane focus "$PH"
  t N05 0 "pane focus <tab id> focuses that tab's pane" -- bash -c "$CLI pane focus $ST --json | jq -e '.data.paneID==\"$SP\"'"
  t N06 0 "pane focus --direction up moves to the pane above" -- bash -c "$CLI pane focus --direction up --project $PID --worktree $WT1 --json | jq -e '.data.paneID==\"$P1\" and .data.moved'"
  t N06b 0 "pane focus --direction up at the edge stays" -- bash -c "$CLI pane focus $P1 --direction up --json | jq -e '.data.moved==false'"
  t N07 2 "pane focus random uuid -> 2" -- cli pane focus "$(uuidgen)"
  t N07b 1 "pane focus without pane or direction -> 1" -- cli pane focus
  t N08 0 "pane resize <id> up" -- cli pane resize "$SP" up
  t N08b 0 "pane resize <tab id> --amount 80 down" -- cli pane resize "$ST" down --amount 80
  t N09 2 "pane resize random uuid -> 2" -- cli pane resize "$(uuidgen)" right
  t N10 1 "pane resize --amount 0 -> 1" -- cli pane resize "$SP" right --amount 0
  t N11 0 "pane zoom zooms" -- bash -c "$CLI pane zoom $SP --json | jq -e '.data.zoomed==true and .data.paneID==\"$SP\"'"
  t N11b 0 "pane zoom again un-zooms" -- bash -c "$CLI pane zoom $SP --json | jq -e '.data.zoomed==false'"
  t N11c 0 "pane zoom --off on an unzoomed pane is a no-op" -- bash -c "$CLI pane zoom $SP --off --json | jq -e '.data.zoomed==false'"
  t N12 0 "pane equalize" -- cli pane equalize --project "$PID" --worktree "$WT1"
  t N13 1 "pane close <tab id> -> 1 naming tab close" -- bash -c "$CLI pane close $ST 2>&1 >/dev/null | grep -q 'tab close' && exit 1"
  t N13b 1 "pane close <content id> -> 1" -- cli pane close "$SC"
  t N13c 1 "pane close <t-handle> -> 1" -- cli pane close "$TH"
  t N13d 0 "the refused pane is still there" -- bash -c "$CLI tab show $ST --json | jq -e '.data.paneID==\"$SP\"'"
  # zsh discards input queued before it finishes starting, so re-send until the shell answers.
  t N14 0 "split tab runs a shell with the project env" -- bash -c "for n in 1 2 3 4 5; do sleep 2; $CLI send --tab $ST 'echo MARK-SPLIT-\$CODANS_CLI' >/dev/null; for i in \$(seq 1 15); do $CLI capture $ST --scope screen | grep -q 'MARK-SPLIT-.*/codans-dev' && exit 0; sleep 0.2; done; done; exit 1"
  t N15 0 "pane close <pane> closes its tabs" -- bash -c "$CLI pane close $SP --json | jq -e '.data.id==\"$SP\" and .data.tabIDs==[\"$ST\"]'"
  t N15b 2 "pane close again -> 2" -- cli pane close "$SP"
  t N15c 2 "its tab is gone too" -- cli tab show "$ST"
  t N16 2 "pane split random uuid -> 2" -- cli pane split "$(uuidgen)"
  t N17 0 "pane split --command prints the new tab id" -- bash -c "$CLI pane split $PH --direction right --command 'echo SPLIT-CMD-MARK' > '$LOGS/N17.id' && grep -qE '^[0-9A-F-]{36}\$' '$LOGS/N17.id'"
  ST2=$(cat "$LOGS/N17.id")
  t N17b 0 "split command output appears in that tab" -- wait_text "$ST2" SPLIT-CMD-MARK 15
  t N17c 0 "pane close <pane> --json (via the split tab's pane)" -- bash -c "p=\$($CLI tab show $ST2 --json | jq -r .data.paneID) && $CLI pane close \$p >/dev/null"
}

phase_terminal() {
  echo "== terminal io"
  t S01 0 "tab send <id> text (Enter)" -- cli tab send "$TAB1" 'echo MARK-S01'
  t S02 0 "readback shows MARK-S01" -- wait_text "$TAB1" MARK-S01
  t S03 1 "send --pane solo (bare word) -> 1 usage error" -- cli send --pane solo 'echo MARK-S03'
  t S04 0 "send --tab @solo" -- cli send --tab @solo 'echo MARK-S04'
  t S05 0 "readback MARK-S04" -- wait_text "$TAB1" MARK-S04
  t S06 0 "tab send --no-enter then send-key enter" -- bash -c "$CLI tab send --no-enter $TAB1 'echo MARK-S06' && $CLI tab send-key $TAB1 enter"
  t S07 0 "readback MARK-S06" -- wait_text "$TAB1" MARK-S06
  t S08 0 "send --stdin --tab" -- bash -c "printf 'echo MARK-S08\n' | $CLI send --stdin --tab $TAB1"
  t S09 0 "readback MARK-S08" -- wait_text "$TAB1" MARK-S08
  t S10 0 "tab send multi-word unquoted" -- cli tab send "$TAB1" echo MARK-S10 more words
  t S11 0 "readback MARK-S10" -- wait_text "$TAB1" 'MARK-S10 more words'
  t S12 2 "tab send echo hi (unquoted) -> 2, no tab titled echo" -- cli tab send echo hi
  t S12b 0 "S12 error names the stray word" -- grep -q 'echo' "$LOGS/S12.err"
  t S13 1 "send no text -> 1" -- cli send
  # stdin is closed explicitly: on an interactive stdin the CLI would block reading it.
  t S14 1 "send --stdin with empty stdin -> 1" -- bash -c "$CLI send --stdin --tab $TAB1 </dev/null"
  t S15 0 "tab send --raw hex (ESC [ A)" -- cli tab send "$TAB1" --raw 1b5b41
  t S16 1 "send --raw + --no-enter -> 1" -- cli send --tab "$TAB1" --raw 1b --no-enter
  t S17 1 "tab send --raw + text -> 1" -- cli tab send "$TAB1" --raw 1b hello
  t S18 "*" "tab send --raw bad hex" -- cli tab send "$TAB1" --raw zz
  t S19 0 "send --raw with 0x and spaces" -- cli send --tab "$TAB1" --raw '0x15 0x0d'
  t S20 0 "tab send --focus" -- cli tab send --focus "$TAB1" 'echo MARK-S20'
  t S20b 1 "send --tab and --pane together -> 1" -- cli send --tab "$TAB1" --pane "$P1" 'x'
  t S20c 0 "send --tab <content id> reaches that tab" -- bash -c "$CLI send --tab $TAB1C 'echo MARK-S20C' --json | jq -e '.data.tabID==\"$TAB1\" and .data.contentID==\"$TAB1C\"'"
  t S20d 0 "send --pane <pane> reaches the pane's selected tab" -- bash -c "$CLI tab focus $TAB1 >/dev/null && $CLI send --pane $P1 'echo MARK-S20D' --json | jq -e '.data.tabID==\"$TAB1\" and .data.paneID==\"$P1\"'"
  t S20e 0 "readback MARK-S20D" -- wait_text "$TAB1" MARK-S20D
  # ctrl_d ends the shell, so the key sweep gets a throwaway tab.
  KEYTAB=$($CLI tab new --pane "$P1" --cwd "$FIX" --json | jq -r '.data | .id'); sleep 1
  t S21 0 "send-key all named keys (throwaway tab)" -- bash -c "for k in escape up down left right tab enter backspace delete home end pgup pgdn f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 ctrl_c ctrl_l ctrl_z ctrl_d; do $CLI send-key --tab $KEYTAB \$k >/dev/null || exit 1; done"
  t S22 0 "tab send-key ctrl-c dashed form" -- cli tab send-key "$TAB1" ctrl-c
  t S23 0 "send-key --tab" -- cli send-key --tab "$TAB1" ctrl_l
  t S24 1 "send-key bogus -> 1" -- cli tab send-key "$TAB1" bogus
  t S25 1 "send-key none -> 1" -- cli send-key
  cli tab close "$KEYTAB" >/dev/null 2>&1
  cli tab send "$TAB1" 'clear; for i in $(seq 1 80); do echo LINE-$i; done; echo MARK-S26' >/dev/null
  wait_text "$TAB1" MARK-S26
  t S26 0 "tab read (zmx dump)" -- cli tab read "$TAB1"
  t S27 0 "tab read contains LINE-80" -- bash -c "$CLI tab read $TAB1 | grep -q LINE-80"
  t S28 0 "tab read --tail 3 -> 3 lines" -- bash -c "$CLI tab read $TAB1 --tail 3 | wc -l | tr -d ' ' | grep -qE '^[1-4]$'"
  t S29 1 "tab read --tail 0 -> 1" -- cli tab read "$TAB1" --tail 0
  t S30 0 "tab read --raw has ESC" -- bash -c "$CLI tab read $TAB1 --raw | grep -q \$'\\x1b'"
  t S31 0 "tab read --range visible" -- cli tab read "$TAB1" --range visible
  t S32 0 "tab send --wait returns once the command finished" -- bash -c "$CLI tab send $TAB1 'sleep 2; echo MARK-WAIT' --wait --json | jq -e '.data.completed==true and .data.waitedMs>=1500'"
  t S33 0 "send --capture returns the command's output" -- bash -c "$CLI send --tab $TAB1 'echo CAP-A; echo CAP-B' --capture --json | jq -e '.data.output|contains(\"CAP-B\")'"
  t S33b 0 "tab send --capture text mode prints the output only" -- bash -c "$CLI tab send $TAB1 'echo CAP-TEXT-ONLY' --capture | grep -qx 'CAP-TEXT-ONLY'"
  t S34 11 "tab send --wait past --wait-timeout -> 11 WAIT_TIMEOUT" -- bash -c "out=\$($CLI tab send $TAB1 'sleep 4' --wait --wait-timeout 1 --json); rc=\$?; jq -e '.error.code==\"WAIT_TIMEOUT\"' <<<\"\$out\" >/dev/null && exit \$rc; exit 99"
  sleep 4
  t S35 1 "tab send --raw with --wait -> 1" -- cli tab send "$TAB1" --raw 1b --wait
  t S36 0 "tab read --json" -- bash -c "$CLI tab read $TAB1 --json | jq -e '.data | .format==\"plain\" and .tabID==\"$TAB1\"'"
  t S37 64 "tab read --screen is not an option -> 64" -- cli tab read "$TAB1" --screen
  t S38 0 "tab capture" -- cli tab capture "$TAB1"
  t S39 0 "capture --tab --lines 5 -> 5 lines" -- bash -c "$CLI capture --tab $TAB1 --lines 5 --json | jq -e '.data | .lines==5'"
  t S40 0 "capture --pane --scope screen" -- cli capture --pane "$P1" --scope screen
  t S41 1 "tab capture --lines 0 -> 1" -- cli tab capture "$TAB1" --lines 0
  t S42 0 "tab capture --wait-stable --json" -- bash -c "$CLI tab capture $TAB1 --wait-stable --json | jq -e '.data | .stabilized==true'"
  t S43 1 "tab capture --wait-stable --timeout-ms >= --timeout -> 1" -- cli tab capture "$TAB1" --wait-stable --timeout-ms 20000
  t S44 1 "capture positional and --tab together -> 1" -- cli capture "$TAB1" --tab "$TAB1"
  t S45 0 "tab capture --scope bogus fails" -- bash -c "$CLI tab capture $TAB1 --scope bogus; test \$? -ne 0"
  echo "== broadcast"
  NP1=$($CLI tab list --pane "$P1" --json | jq '.data.tabs|length')
  t B01 0 "broadcast --pane" -- cli broadcast --pane "$P1" 'echo MARK-B01'
  t B02 0 "readback in tab1" -- wait_text "$TAB1" MARK-B01
  t B03 0 "broadcast --pane delivered == the pane's tab count ($NP1)" -- bash -c "$CLI broadcast --pane $P1 --json 'echo MARK-B03' | jq -e '.data | .delivered==$NP1'"
  t B03b 0 "broadcast --pane <tab id> means that tab's pane" -- bash -c "$CLI broadcast --pane $TAB2 --json 'echo MARK-B03B' | jq -e '.data | .delivered==$NP1'"
  t B04 0 "broadcast --worktree" -- cli broadcast --worktree "$WT1" 'echo MARK-B04'
  t B05 0 "broadcast --label" -- cli broadcast --label agent 'echo MARK-B05'
  t B06 0 "broadcast --label unknown delivered==0" -- bash -c "$CLI broadcast --label nolabel --json 'x' | jq -e '.data | .delivered==0'"
  t B07 1 "broadcast no scope -> 1" -- cli broadcast 'x'
  t B08 1 "broadcast two scopes -> 1" -- cli broadcast --pane "$P1" --label a 'x'
  t B08b 64 "broadcast --tab is not a scope -> 64" -- cli broadcast --tab "$TAB1" 'x'
  t B09 0 "broadcast --stdin --no-enter" -- bash -c "printf 'echo MARK-B09' | $CLI broadcast --pane $P1 --stdin --no-enter"
  cli broadcast --pane "$P1" --stdin --no-enter <<<'' >/dev/null 2>&1; cli tab send-key "$TAB1" enter >/dev/null
  t B10 1 "broadcast --stdin + text -> 1" -- bash -c "echo x | $CLI broadcast --pane $P1 --stdin 'y'"
  t B11 2 "broadcast --pane current outside a tab -> 2" -- cli broadcast --pane current 'x'
}

phase_incontext() {
  echo "== in-tab context (commands run inside tab1 through tab send)"
  # Each probe writes `CTX-<id>=<exit>` on the tab's screen.
  ctx() { # ctx <id> <cmdline>
    local id="$1"; shift
    cli tab send "$TAB1" "clear; $* >/tmp/codans-ctx-$id.out 2>&1; echo CTX-$id=\$?" >/dev/null
    # Wait for the marker *with* an exit code: the echoed command line itself
    # shows `CTX-<id>=$?` until `clear` runs, and would satisfy a bare prefix.
    wait_text "$TAB1" "CTX-$id=[0-9]" 10
    local line; line=$(cli tab capture "$TAB1" --scope screen | grep -o "CTX-$id=[0-9]*" | tail -1)
    echo "${line#*=}"
  }
  cli tab focus "$TAB1" >/dev/null
  # The tab's environment carries exactly its three ids.
  ctx X20 'env | grep -E "^CODANS_(PANE|TAB|CONTENT)_ID=" | sort | tr "\n" " "' >/dev/null
  cp /tmp/codans-ctx-X20.out "$LOGS/X20.env"
  note "tab env ids: $(cat /tmp/codans-ctx-X20.out)"
  t X20 0 "CODANS_PANE_ID / CODANS_TAB_ID / CODANS_CONTENT_ID name the calling pane / tab / content" -- bash -c "grep -q 'CODANS_CONTENT_ID=$TAB1C' '$LOGS/X20.env' && grep -q 'CODANS_PANE_ID=$P1' '$LOGS/X20.env' && grep -q 'CODANS_TAB_ID=$TAB1' '$LOGS/X20.env'"
  # `send-key escape` stays last: the ESC it types into this very shell
  # would swallow the start of the next probe's command line.
  for spec in \
    "X01|tree --project current|0" \
    "X02|send 'echo CTX-INNER'|0" \
    "X03|tab read|0" \
    "X04|tab capture --lines 3|0" \
    "X05|tab info|0" \
    "X06|project commands list|0" \
    "X07|tab new --json|0" \
    "X08|pane split --json|0" \
    "X09|broadcast --pane current 'echo CTX-BC'|0" \
    "X10|worktree new test/ctx-wt --json|0" \
    "X11|pane focus current|0" \
    "X12|tab label current ctxlabel|0" \
    "X13|agent list|0" \
    "X14|doctor --json|0" \
    "X16|tab focus current|0" \
    "X17|worktree switch current|0" \
    "X18|tab show current --json|0" \
    "X19|pane list --json|0" \
    "X15|send-key escape|0" \
    ; do
    IFS='|' read -r id cmd want <<<"$spec"
    got=$(ctx "$id" "codans-dev $cmd")
    verdict=PASS; [[ "$got" != "$want" ]] && verdict=FAIL
    [[ $verdict == PASS ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
    cp "/tmp/codans-ctx-$id.out" "$LOGS/$id.out" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$verdict" "$want" "$got" "in-tab: codans-dev $cmd" "" >>"$RESULTS"
    printf '%-8s %-4s want=%-3s got=%-3s in-tab: codans-dev %s\n' "$id" "$verdict" "$want" "$got" "$cmd"
    [[ $verdict == FAIL ]] && head -2 "$LOGS/$id.out" | sed 's/^/    out: /'
  done
  t X07b 0 "tab new in a tab opens on the caller's pane" -- bash -c "jq -e '.data.paneID==\"$P1\"' '$LOGS/X07.out'"
  t X08b 0 "pane split in a tab splits the caller's pane (new pane, new tab)" -- bash -c "jq -e '.data.anchor==\"$P1\" and (.data.paneID!=\"$P1\")' '$LOGS/X08.out'"
  t X18b 0 "tab show current is the calling tab" -- bash -c "jq -e '.data.id==\"$TAB1\" and .data.contentID==\"$TAB1C\" and .data.paneID==\"$P1\"' '$LOGS/X18.out'"
  # cleanup what the probes created
  local made; made=$(jq -r '.data.id' "$LOGS/X07.out" 2>/dev/null || true)
  [[ -n "$made" && "$made" != null ]] && cli tab close "$made" >/dev/null 2>&1
  made=$(jq -r '.data.paneID' "$LOGS/X08.out" 2>/dev/null || true)
  [[ -n "$made" && "$made" != null ]] && cli pane close "$made" >/dev/null 2>&1
  local ctxwt; ctxwt=$(jq -r '.data | .id' "$LOGS/X10.out" 2>/dev/null || true)
  [[ -n "$ctxwt" && "$ctxwt" != null ]] && cli worktree rm "$ctxwt" --project "$PID" >/dev/null 2>&1
  for f in /tmp/codans-ctx-*.out; do rm -f "$f"; done
}

phase_agent_handoff() {
  echo "== agent"
  t G01 0 "agent list" -- cli agent list
  t G02 0 "agent list --json has 3 profiles" -- bash -c "$CLI agent list --json | jq -e '.data | .profiles|length==3'"
  t G03 1 "agent launch no args -> 1" -- cli agent launch --project "$PID" --worktree "$WT1"
  t G04 1 "agent launch --tab --split -> 1" -- cli agent launch 'Fake Amp' --tab --split right --project "$PID" --worktree "$WT1"
  t G05 2 "agent launch unknown profile -> 2" -- cli agent launch 'No Such Profile' --project "$PID" --worktree "$WT1"
  t G06 3 "agent launch disabled profile -> 3" -- cli agent launch 'Disabled Codex' --project "$PID" --worktree "$WT1"
  t G07 0 "agent launch 'Fake Amp' --background --json" -- cli agent launch 'Fake Amp' --background --project "$PID" --worktree "$WT1" --json
  AGTAB=$(jf G07 .tabID)
  t G07b 0 "agent launch reports tab, content, and pane ids" -- bash -c "jq -e '.data | (.tabID|length==36) and (.contentID|length==36) and (.paneID|length==36)' '$LOGS/G07.out'"
  t G08 0 "fake amp started in the new tab" -- wait_text "$AGTAB" 'FAKE-AGENT amp' 10
  t G09 4 "agent launch amp --prompt -> 4 unsupported" -- cli agent launch --agent amp --prompt 'hi' --project "$PID" --worktree "$WT1"
  t G10 0 "agent launch --agent claude --prompt - (stdin) --split right" -- bash -c "echo 'do the thing' | $CLI agent launch --agent claude --prompt - --split right --project $PID --worktree $WT1 --json"
  AGTAB2=$(jf G10 .tabID); AGPANE2=$(jf G10 .paneID)
  t G10b 0 "--split put the agent on a new pane" -- bash -c "test '$AGPANE2' != '$P1' && $CLI tab show $AGTAB2 --json | jq -e '.data.paneID==\"$AGPANE2\"'"
  t G11 0 "fake claude got prompt on argv" -- wait_text "$AGTAB2" 'do the thing' 10
  t G12 1 "agent launch --prompt '' -> 1" -- cli agent launch --agent claude --prompt '   ' --project "$PID" --worktree "$WT1"
  t G13 2 "agent launch --worktree current outside a tab -> 2" -- cli agent launch --agent claude --project "$PID"
  t G14 0 "agent launch --worktree <branch> --background" -- cli agent launch 'Fake Amp' --background --worktree bugfix/menu --json
  AGTAB3=$(jf G14 .tabID)
  echo "== agent status / wait"
  AGC=$(jf G07 .contentID)
  t G15 0 "agent status" -- cli agent status
  t G15b 0 "agent status --json lists the launched fake amp (classifier may take a while)" -- bash -c "for i in \$(seq 1 150); do $CLI agent status --json | jq -e '.data.agents[]|select(.contentID==\"$AGC\" and .agent==\"amp\" and .tabID==\"$AGTAB\")' >/dev/null 2>&1 && exit 0; sleep 0.2; done; $CLI agent status --json; exit 1"
  t G15c 0 "agent status entries carry the tab handle + pane + containers" -- bash -c "$CLI agent status --json | jq -e '.data.count>=1 and (.data.agents[0].handle|startswith(\"t\")) and (.data.agents[0].paneID|length==36) and (.data.agents[0].worktreeID|length==36)'"
  t G16 0 "agent wait --until exit on a plain shell tab resolves at once" -- bash -c "$CLI agent wait $TAB1 --until exit --wait-timeout 5 --json | jq -e '.data.satisfied==true and .data.waitedMs<1000 and .data.contentID==\"$TAB1C\"'"
  t G16b 0 "agent wait <pane id> waits on the pane's selected tab" -- bash -c "$CLI agent wait $P1 --until exit --wait-timeout 5 --json | jq -e '.data.satisfied==true'"
  t G17 11 "agent wait --until working on a plain shell tab -> 11 WAIT_TIMEOUT" -- bash -c "out=\$($CLI agent wait $TAB1 --until working --wait-timeout 1 --json); rc=\$?; jq -e '.error.code==\"WAIT_TIMEOUT\" and .error.details.until==\"working\"' <<<\"\$out\" >/dev/null && exit \$rc; exit 99"
  t G18 2 "agent wait random uuid -> 2" -- cli agent wait "$(uuidgen)" --until idle --wait-timeout 1
  t G19 1 "agent wait --timeout 0 -> 1" -- cli agent wait "$TAB1" --until idle --wait-timeout 0
  t G20 64 "agent wait --until bogus -> 64" -- cli agent wait "$TAB1" --until bogus
  echo "== handoff"
  t H01 1 "handoff to bogus agent -> 1" -- cli handoff to bogus --pane "$TAB1" --no-brief
  t H02 1 "handoff to amp neither brief nor no-brief -> 1" -- cli handoff to amp --pane "$TAB1"
  t H03 1 "handoff --brief + --no-brief -> 1" -- cli handoff to amp --pane "$TAB1" --brief x --no-brief
  t H04 1 "handoff --brief '' -> 1" -- cli handoff to amp --pane "$TAB1" --brief '  '
  t H05 1 "handoff to amp --brief missing sections -> 1" -- cli handoff to amp --pane "$TAB1" --brief 'just text' --no-launch
  t H06 0 "handoff save --brief - (heredoc)" -- bash -c "$CLI handoff save --pane $TAB1 --brief - <<'EOF'
# Handoff
## Objective
Test objective
## Current State
State
## Next Steps
1. go
EOF"
  t H07 0 "current.md written in worktree" -- test -f "$WT1PATH/.codans/handoff/current.md"
  t H08 0 "handoff save --no-brief (context only)" -- cli handoff save --pane "$TAB1" --no-brief --json
  t H09 0 "handoff to amp --no-brief --no-launch --json" -- cli handoff to amp --pane "$TAB1C" --no-brief --no-launch --json
  # A split receiver's surface comes up with its tab; make the source tab the visible one first.
  cli tab focus "$TAB1" >/dev/null; sleep 1
  t H10 0 "handoff to amp --profile 'Fake Amp' --split down --no-brief (launches fake)" -- cli handoff to amp --pane "$TAB1" --profile 'Fake Amp' --split down --no-brief --json
  t H10b 0 "handoff --json prints launchedPane tab / content / pane ids" -- bash -c "jq -e '.data | (.launchedPane.contentID|type==\"string\") and (.launchedPane.tabID|type==\"string\") and (.launchedPane.paneID!=\"$P1\")' '$LOGS/H10.out'"
  HOTAB=$(jf H10 .launchedPane.tabID)
  t H11 0 "receiver fake amp came up" -- wait_text "$HOTAB" 'FAKE-AGENT amp' 15
  if [[ -n "$HOTAB" && "$HOTAB" != null ]]; then
    { cli tree --project "$PID"; cli tab info "$HOTAB"; cli tab read "$HOTAB" --tail 20; cli tab capture "$HOTAB" --scope screen; } > "$LOGS/H11.diag" 2>&1
  fi
  # The kickoff is typed once the foreground-job classifier has seen the agent; that poll
  # can take tens of seconds for a fresh tab, so this is the run's longest wait.
  t H12 0 "typed kickoff reached fake amp (RECEIVED:)" -- wait_text "$HOTAB" 'RECEIVED:' 75
  t H13 1 "handoff to amp --tab --split -> 1" -- cli handoff to amp --pane "$TAB1" --tab --split up --no-brief
  t H14 2 "handoff to claude --pane current outside a tab -> 2" -- cli handoff to claude --no-brief --no-launch
  for tab in "$AGTAB" "$AGTAB2" "$AGTAB3" "$HOTAB"; do [[ -n "$tab" && "$tab" != null ]] && cli tab close "$tab" >/dev/null 2>&1; done
}

phase_close() {
  echo "== close & teardown"
  t Z01 0 "tab close <id>" -- bash -c "$CLI tab close $TAB2 --json | jq -e '.data.id==\"$TAB2\" and .data.contentID==\"$TAB2C\"'"
  t Z02 2 "tab close again -> 2" -- cli tab close "$TAB2"
  t Z03 0 "tab close @solo (label)" -- cli tab close @solo
  t Z03b 2 "tab1 is gone" -- cli tab show "$TAB1"
  # any leftovers, by pane
  for p in $($CLI tree --project "$PID" --json | jq -r '.data | .projects[].worktrees[].panes[].id'); do cli pane close "$p" >/dev/null 2>&1; done
  t Z04 0 "tree has no panes left" -- bash -c "$CLI tree --project $PID --json | jq -e '[.data.projects[].worktrees[].panes[]]|length==0'"
  t Z07 0 "worktree rm wt1 --delete (project inferred)" -- cli worktree rm "$WT1" --delete
  t Z08 0 "project rm by name" -- cli project rm fixture
  t Z09 0 "tree empty" -- bash -c "$CLI tree --json | jq -e '.data | .projects|length==0'"
  quit_app
  t Z10 10 "status after quit -> 10" -- cli status
  t Z11 0 "doctor after quit reports app-not-running/socket-missing" -- bash -c "$CLI doctor --json | jq -e '.data | .socketStatus==\"app-not-running\" or .socketStatus==\"socket-missing\"'"
}

case "$PHASE" in
  all)
    setup; launch_app
    phase_app; phase_project; phase_worktree; phase_tab; phase_pane; phase_terminal; phase_incontext; phase_agent_handoff; phase_close
    ;;
  setup) setup; launch_app ;;
  quit) quit_app ;;
  *) echo "unknown phase $PHASE"; exit 2 ;;
esac
if [[ "$PHASE" == all ]]; then
  echo "== json contract"
  t J01 0 "every --json output matches the CLI output schema" -- python3 "$HERE/validate-json.py" "$REPO_ROOT/apps/mac/codans-cli/Resources/schema/cli-output.schema.json" "$LOGS"/*.out
fi
echo "PASS=$PASS FAIL=$FAIL  (results: $RESULTS)"
