#!/usr/bin/env bash
# End-to-end smoke test of the self-verify workflow against the real Debug
# build: launch, CLI terminal round trip, AX actions in the main window, a
# popover, and Settings, a window screenshot, and cleanup without leftovers.
# No semantic step may take focus from the frontmost app.
#
# Usage (repository root, after `make mac-build`):
#   bash .claude/skills/self-verify-codans/scripts/smoke_test.sh
#   SV_TEST_PHYSICAL=1 adds the hover-revealed branch switch; it activates
#   the instance for about a second and then gives focus back.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
export SELF_VERIFY_DIR="${TMPDIR%/}/codans-self-verify-smoke-$(id -u)"
export SELF_VERIFY_SOCKET="/tmp/cdv-smoke-$(id -u).sock"
export SELF_VERIFY_CACHE="/tmp/cdv-smoke-cache-$(id -u)"
# shellcheck source=helpers.sh
. .claude/skills/self-verify-codans/scripts/helpers.sh

failures=0
out="$(mktemp "${TMPDIR:-/tmp}/sv-smoke.XXXXXX")"
pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
check() {
  local name="$1"
  shift
  if "$@" >"$out" 2>&1; then pass "$name"; else
    fail "$name"
    sed 's/^/     /' "$out"
  fi
}
# poll <command...>: retry for up to 3 s
poll() {
  local i
  for i in $(seq 1 30); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  "$@"
}
trap 'sv_cleanup >/dev/null 2>&1; rm -f "$out"' EXIT

front="$(sv_tool front)"
sv_seed_settings
fixture="$(sv_fixture_repo)"
check "instance launches on the private socket" sv_launch
check "launch left focus on the user's app" test "$(sv_tool front)" = "$front"
check "the PID is this worktree's Debug executable" sv_pid

# ---------- CLI ----------
project="$(codans_debug project add "$fixture" --json | jq -r '.data.id')"
worktree="$(codans_debug tree --json | jq -r '.data.projects[0].worktrees[0].id')"
tab="$(codans_debug tab new smoke --project "$project" --worktree "$worktree" --json | jq -r '.data.id')"
pane="$(codans_debug pane new --project "$project" --worktree "$worktree" --tab "$tab" --cwd "$fixture" --json |
  jq -r '.data.id')"
check "project, tab, and pane ids are returned" test -n "$project" -a -n "$tab" -a -n "$pane"
codans_debug pane send "$pane" 'printf "SMOKE:%s\n" "$(basename "$PWD")"' --capture --json >"$SELF_VERIFY_DIR/send.json"
check "a command runs in the pane and its output comes back" grep -q 'SMOKE:fixture' "$SELF_VERIFY_DIR/send.json"
check "the pane runs under the private cache dir" test -S "$SELF_VERIFY_CACHE/$pane"
codans_debug pane focus "$pane" >/dev/null

# ---------- AX: main window ----------
# The branch button's label changes with branch state; its identifier does not.
check "AX tree shows the worktree header" sv_find AXButton worktree_header.branch_button
check "press toggles the agents view" sv_press AXButton "Hide agents view"
check "the toggle label flipped" sv_wait AXButton "Show agents view" --timeout 3000
check "press restores the agents view" sv_press AXButton "Show agents view"
check "the label flipped back" sv_wait AXButton "Hide agents view" --timeout 3000

# ---------- AX: popover ----------
check "press opens the branch popover" sv_press AXButton worktree_header.branch_button
check "the filter field appears" sv_wait AXTextField "Filter branches" --timeout 3000
check "the popover lists main" sv_wait any branch_switcher.branch_row.local.main --timeout 3000
check "set-value filters the branch list" sv_set_value AXTextField "Filter branches" bug
check "only the matching row is left" sv_wait any branch_switcher.branch_row.local.main --gone --timeout 3000
check "the matching row stays" sv_find any branch_switcher.branch_row.local.bugfix/menu
check "the branch row has no AXPress, so press refuses it" sh -c '! "$1" press "$2" AXStaticText bugfix/menu' _ "$SELF_VERIFY_DIR/sv-tool" "$(sv_pid)"
check "press closes the popover" sv_press AXButton worktree_header.branch_button
check "the popover is gone" sv_wait AXTextField "Filter branches" --gone --timeout 3000

# ---------- AX: split button menu ----------
check "the chevron opens the Open-in menu" sv_press AXMenuButton "" --within "Open in Cursor"
check "the menu lists editors" sv_wait AXMenuItem Zed --timeout 3000
check "cancel-menu closes it without a choice" sv_cancel_menu
check "the menu is gone" sv_wait AXMenuItem Zed --gone --timeout 3000

# ---------- physical: hover-revealed branch actions ----------
if [ "${SV_TEST_PHYSICAL:-0}" = 1 ]; then
  sv_physical_begin
  sv_press AXButton worktree_header.branch_button >/dev/null
  sv_wait AXTextField "Filter branches" --timeout 3000 >/dev/null
  read -r bx by <<<"$(sv_center AXStaticText bugfix/menu)"
  check "hover moves onto the bugfix/menu row" sv_hover "$bx" "$by"
  check "hover reveals Branch actions" sv_wait AXMenuButton "Branch actions" --timeout 3000
  check "press opens Branch actions" sv_press AXMenuButton "Branch actions"
  check "press picks Switch" sh -c '"$1" wait "$2" AXMenuItem Switch --timeout 3000 && "$1" press "$2" AXMenuItem Switch' _ "$SELF_VERIFY_DIR/sv-tool" "$(sv_pid)"
  sv_physical_end
  check "focus is back after the physical block" test "$(sv_tool front)" = "$front"
  check "the worktree is on bugfix/menu (CLI)" poll sh -c "test \"\$(git -C '$fixture' branch --show-current)\" = bugfix/menu"
fi

# ---------- AX: Settings ----------
check "the menu bar opens Settings" sv_menu Codans "Settings…"
check "the Settings window appears" poll sv_windows General
check "select-row navigates the sidebar" sv_select_row Notifications
check "the window title follows the selection" poll sv_windows Notifications
dock_badge_is() { test "$(jq -r '.notifications.dockBadgeEnabled' "$SELF_VERIFY_DIR/conf/settings.json")" = "$1"; }
check "the unlabelled Dock badge switch is found by its row text" sv_get AXCheckBox "*" --after "Show Dock badge"
check "press turns the Dock badge switch off" sv_press AXCheckBox "*" --after "Show Dock badge"
check "settings.json records the change" poll dock_badge_is false
check "press turns it back on" sv_press AXCheckBox "*" --after "Show Dock badge"
check "settings.json is restored" poll dock_badge_is true
check "a Settings screenshot is captured by window id" sv_screenshot "$SELF_VERIFY_DIR/settings.png" Notifications
check "the screenshot is a PNG" sh -c "file '$SELF_VERIFY_DIR/settings.png' | grep -q PNG"
check "close-window closes Settings" sv_close_window Notifications
check "no step took focus" test "$(sv_tool front)" = "$front"

# ---------- cleanup ----------
pid="$(sv_pid)"
SELF_VERIFY_KEEP_DIR=0 sv_cleanup >"$out" 2>&1
trap 'rm -f "$out"' EXIT
check "the instance process is gone" sh -c "! kill -0 $pid 2>/dev/null"
check "no process holds the cache dir" test -z "$(sv_cache_pids)"
check "the socket is removed" test ! -e "$SELF_VERIFY_SOCKET"
check "the scratch dir is removed" test ! -e "$SELF_VERIFY_DIR"

printf '\n%s failure(s)\n' "$failures"
[ "$failures" -eq 0 ]
