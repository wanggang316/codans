#!/usr/bin/env bash
# Integration test for sv-tool.swift against a SwiftUI fixture app. Each
# command must produce its effect, observed through AX, and no semantic
# command may take focus from the frontmost app.
#
# Usage: bash .claude/skills/self-verify-codans/scripts/sv_tool_test.sh
#   SV_TEST_PHYSICAL=1 also runs the guarded click and hover cases. They
#   activate the fixture for a moment and then give focus back.

set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sv-tool-test.XXXXXX")"
failures=0
fixture_pid=""

cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null
    wait "$fixture_pid" 2>/dev/null
  fi
  rm -rf "$scratch"
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
check_exit() { # check_exit <name> <wanted exit> <command...>
  local name="$1" want="$2" got
  shift 2
  "$@" >"$scratch/out" 2>&1
  got=$?
  if [ "$got" = "$want" ]; then pass "$name"; else
    fail "$name (wanted exit $want, got $got)"
    sed 's/^/     /' "$scratch/out"
  fi
}

printf 'compiling sv-tool and the fixture app...\n'
swiftc -O "$script_dir/sv-tool.swift" -o "$scratch/sv-tool" || exit 1
swiftc -O "$script_dir/test-fixture/FixtureApp.swift" -o "$scratch/SvFixture" || exit 1
tool="$scratch/sv-tool"

if ! "$tool" preflight >"$scratch/preflight"; then
  printf 'SKIPPED: %s\n' "$(cat "$scratch/preflight")"
  exit 2
fi

front_before="$("$tool" front)"
"$scratch/SvFixture" >"$scratch/fixture.log" 2>&1 &
fixture_pid=$!
for _ in $(seq 1 50); do
  "$tool" windows "$fixture_pid" "Fixture Main" >/dev/null 2>&1 && break
  sleep 0.1
done
p="$fixture_pid"
ax() { "$tool" "$1" "$p" "${@:2}"; }
window_gone() { # window_gone <title>: poll up to 2 s
  for _ in $(seq 1 20); do
    "$tool" windows "$p" "$1" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  return 1
}

check "fixture window is on screen" "$tool" windows "$p" "Fixture Main"
# A GUI app started from the frontmost app's terminal can inherit
# activation. That is the launch, not sv-tool: give focus back first.
sleep 0.5
[ "$("$tool" front)" = "$p" ] && "$tool" activate "$front_before"
check "focus is on the original app before the commands" test "$("$tool" front)" = "$front_before"

# ---------- observation ----------
check "tree shows the toggle with its identifier and action" sh -c "'$tool' tree $p | grep -q 'AXButton \"Toggle\" #fixture.toggle {Press}'"
check "tree --window limits the dump to one window" sh -c "! '$tool' tree $p --window 'Fixture Second' | grep -q Toggle"
check "find matches an identifier" ax find any fixture.toggle
check_exit "find exits 1 when nothing matches" 1 ax find AXButton "No such button"
check "get reports frame and actions" sh -c "'$tool' get $p AXButton Toggle | jq -e '.frame.w > 0 and (.actions | index(\"AXPress\"))'"
check_exit "get refuses an ambiguous label" 1 ax get AXButton Dup
check_exit "wait times out with exit 2" 2 ax wait AXStaticText "state: on" --timeout 300

# ---------- semantic actions ----------
check "press runs the button action" ax press AXButton Toggle
check "the press took effect" ax wait AXStaticText "state: on" --timeout 2000
check_exit "press refuses an element without AXPress" 1 ax press AXStaticText "Tap target"
check "the refused press did nothing" ax find AXStaticText "taps: 0"
check "set-value types into a text field" ax set-value AXTextField Name abc
check "the value reached the binding" ax wait AXStaticText "name: abc" --timeout 2000
check "press opens the popup menu" ax press AXPopUpButton A
check "the popup menu is open" ax wait AXMenuItem B --timeout 2000
check "cancel-menu dismisses it" ax cancel-menu
check "the menu is gone" ax wait AXMenuItem B --gone --timeout 2000
ax press AXPopUpButton A >/dev/null 2>&1
ax wait AXMenuItem B --timeout 2000 >/dev/null 2>&1
check "press picks a popup item" ax press AXMenuItem B
check "the popup selection changed" ax wait AXStaticText "mode: B" --timeout 2000
check "the popup menu closed after the pick" ax wait AXMenuItem B --gone --timeout 2000
check "an empty label with --near finds the split chevron" ax find AXMenuButton "" --near Split
check "press opens the split menu from the chevron" ax press AXMenuButton "" --near Split
check "press picks the split menu item" sh -c '"$1" wait "$2" AXMenuItem "Split item" --timeout 2000 && "$1" press "$2" AXMenuItem "Split item"' _ "$tool" "$p"
check "the split item ran, not the primary action" ax wait AXStaticText "split: item" --timeout 2000
check "select-row selects a list row" ax select-row "Row 2"
check "the row selection changed" ax wait AXStaticText "row: Row 2" --timeout 2000
check "menu presses a menu-bar item" ax menu Fixture Bump
check "the menu action ran" ax wait AXStaticText "bumps: 1" --timeout 2000
check_exit "menu reports a missing item" 1 ax menu Fixture Nope
check "main-window targets a window by title" ax main-window "Fixture Second"
check "close-window closes it" ax close-window "Fixture Second"
check "the closed window is off screen" window_gone "Fixture Second"
check "center prints a point inside the element" sh -c "'$tool' center $p AXButton Toggle | grep -Eq '^[0-9]+ [0-9]+$'"
check "no semantic command took focus" test "$("$tool" front)" = "$front_before"

# ---------- guarded physical input ----------
check_exit "click outside the fixture is refused" 1 "$tool" click "$p" 0 0
check "the refused click did not take focus" test "$("$tool" front)" = "$front_before"
if [ "${SV_TEST_PHYSICAL:-0}" = 1 ]; then
  cursor_before="$("$tool" cursor)"
  read -r tx ty <<<"$(ax center AXStaticText "Tap target")"
  check "click reaches a tap gesture" "$tool" click "$p" "$tx" "$ty"
  check "the tap took effect" ax wait AXStaticText "taps: 1" --timeout 2000
  check "click gave focus back" test "$("$tool" front)" = "$front_before"
  check "click put the cursor back" test "$("$tool" cursor)" = "$cursor_before"
  read -r hx hy <<<"$(ax center AXStaticText "Hover row")"
  check "hover moves onto the row" "$tool" hover "$p" "$hx" "$hy"
  check "hover reveals the hidden button" ax wait AXButton "Hover action" --timeout 2000
  check "the revealed button takes a semantic press" ax press AXButton "Hover action"
  check "the revealed button ran" ax wait AXStaticText "hover presses: 1" --timeout 2000
  "$tool" warp "${cursor_before% *}" "${cursor_before#* }"
  "$tool" activate "$front_before"
  check "focus is back after the hover sequence" test "$("$tool" front)" = "$front_before"
else
  printf 'skip physical cases (set SV_TEST_PHYSICAL=1)\n'
fi

printf '\n%s failure(s)\n' "$failures"
[ "$failures" -eq 0 ]
