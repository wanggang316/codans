#!/usr/bin/env bash
# UT-V11-J-001 — controller-driven probe (replayable).
# Requires the feature-branch build at the DerivedData path below.

set -eu
FEATURE_APP=~/Library/Developer/Xcode/DerivedData/codans-chgukochxcibwaglczplbvhgcaqu/Build/Products/Debug/Codans.app
FEATURE_TC=$FEATURE_APP/Contents/Resources/bin/codans
INBOX=~/.config/codans/notifications.json

cp -p "$INBOX" "${INBOX}.user-backup" 2>/dev/null || true
rm -f "$INBOX"

# Quit any running Codans before launching feature build, then:
open "$FEATURE_APP"; sleep 5

# Pick the active worktree's first pane id from `codans tree` and send OSC 9.
PANE=$($FEATURE_TC tree | awk '/\[\*\] Worktree/{w=1} w && /\[\*\] Tab/{t=1} t && /Pane 1:/{print; exit}' \
       | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1)
$FEATURE_TC pane send --pane "$PANE" --raw "1b5d393b68656c6c6f07"
sleep 3

jq '{has_version: has("version"), has_entries: has("entries"), version: .version, entries_count: (.entries | length)}' "$INBOX"
