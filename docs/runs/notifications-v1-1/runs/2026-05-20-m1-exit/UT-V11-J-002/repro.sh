#!/usr/bin/env bash
# UT-V11-J-002 — controller-driven probe (replayable).

set -eu
FEATURE_APP=~/Library/Developer/Xcode/DerivedData/codans-chgukochxcibwaglczplbvhgcaqu/Build/Products/Debug/Codans.app
FEATURE_TC=$FEATURE_APP/Contents/Resources/bin/codans
INBOX=~/.config/codans/notifications.json

cp -p "$INBOX" "${INBOX}.user-backup" 2>/dev/null || true

# Seed legacy bare-array: 2 unread, 1 read.
cat > "$INBOX" <<'JSON'
[
  {"id":{"raw":"11111111-1111-1111-1111-111111111111"},"kind":"waitingForInput","title":"Seeded legacy entry A","body":"Seed","createdAt":800975000.0,"source":{"projectID":{"raw":"AAAAAAAA-1111-1111-1111-111111111111"},"worktreeID":{"raw":"BBBBBBBB-1111-1111-1111-111111111111"},"tabID":{"raw":"CCCCCCCC-1111-1111-1111-111111111111"},"paneID":{"raw":"DDDDDDDD-1111-1111-1111-111111111111"}}},
  {"id":{"raw":"22222222-2222-2222-2222-222222222222"},"kind":"taskFinished","title":"Seeded legacy entry B","body":"Seed","createdAt":800975100.0,"source":{"projectID":{"raw":"AAAAAAAA-1111-1111-1111-111111111111"},"worktreeID":{"raw":"BBBBBBBB-1111-1111-1111-111111111111"},"tabID":{"raw":"CCCCCCCC-1111-1111-1111-111111111111"},"paneID":{"raw":"DDDDDDDD-1111-1111-1111-111111111111"}}},
  {"id":{"raw":"33333333-3333-3333-3333-333333333333"},"kind":"taskFinished","title":"Seeded legacy entry C (read)","body":"Seed","createdAt":800975200.0,"readAt":800975250.0,"source":{"projectID":{"raw":"AAAAAAAA-1111-1111-1111-111111111111"},"worktreeID":{"raw":"BBBBBBBB-1111-1111-1111-111111111111"},"tabID":{"raw":"CCCCCCCC-1111-1111-1111-111111111111"},"paneID":{"raw":"DDDDDDDD-1111-1111-1111-111111111111"}}}
]
JSON

open "$FEATURE_APP"; sleep 5

# Inspect post-launch shape (expected: envelope, count==3)
jq 'if type=="array" then {shape:"bare-array",count:length} else {shape:"envelope",version:.version,count:(.entries|length)} end' "$INBOX"

# Trigger a new event.
PANE=$($FEATURE_TC tree | awk '/\[\*\] Worktree/{w=1} w && /\[\*\] Tab/{t=1} t && /Pane 1:/{print; exit}' \
       | grep -oE '[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}' | head -1)
$FEATURE_TC pane send --pane "$PANE" --raw "1b5d393b777269746500"
sleep 3

jq '{version: .version, count: (.entries | length), titles: (.entries | map(.title))}' "$INBOX"
