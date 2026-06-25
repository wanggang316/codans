#!/usr/bin/env bash
#
# Sentry issue helper for the `crash-resolve` skill.
#
# Operates the codans Sentry project over the REST API so the agent does
# not hand-roll curl + token extraction + JSON parsing on every step.
#
# Auth:  $SENTRY_AUTH_TOKEN, else the [auth] token= line in ~/.sentryclirc.
# Coordinates (override via env):
#   SENTRY_ORG=thinking-function   SENTRY_PROJECT=apple-macos
#
# Read commands (list/show/event) need an `event:read`-scoped token; the
# mutating commands (resolve/resolve-next/archive/unresolve/assign/comment)
# additionally need `event:write`. A 403 means the token is missing a
# scope — mint a new one at Sentry → Settings → Auth Tokens.
#
# Issue ids are the friendly short ids from the dashboard, e.g.
# APPLE-MACOS-4. The org-scoped endpoints accept them directly.
set -euo pipefail

API="${SENTRY_API:-https://sentry.io/api/0}"
ORG="${SENTRY_ORG:-thinking-function}"
PROJECT="${SENTRY_PROJECT:-apple-macos}"

die() { printf 'sentry: %s\n' "$*" >&2; exit 1; }

token() {
  if [[ -n "${SENTRY_AUTH_TOKEN:-}" ]]; then printf '%s' "$SENTRY_AUTH_TOKEN"; return; fi
  if [[ -f "$HOME/.sentryclirc" ]]; then
    local t
    t="$(awk -F'=' '/^[[:space:]]*token[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.sentryclirc")"
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
  fi
  die "no auth token: set SENTRY_AUTH_TOKEN or add a [auth] token= line to ~/.sentryclirc"
}

# api METHOD PATH [json-body]  — prints raw JSON, fails loud on non-2xx.
api() {
  local method="$1" path="$2" body="${3:-}" tok code out
  tok="$(token)"
  if [[ -n "$body" ]]; then
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" "$API$path" \
      -H "Authorization: Bearer $tok" -H "Content-Type: application/json" --data "$body")"
  else
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" "$API$path" -H "Authorization: Bearer $tok")"
  fi
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    printf '%s\n' "$out" >&2
    die "HTTP $code on $method $path"
  fi
  printf '%s' "$out"
}

py() { python3 -c "$1" "${@:2}"; }

cmd_list() {  # list [query] [period:14d|24h|'']
  local query="${1:-is:unresolved}" period="${2:-14d}" tok
  tok="$(token)"
  curl -sS -G "$API/projects/$ORG/$PROJECT/issues/" \
    -H "Authorization: Bearer $tok" \
    --data-urlencode "query=$query" \
    --data-urlencode "statsPeriod=$period" \
    --data "limit=25" --data "sort=freq" \
  | py '
import sys, json
d = json.load(sys.stdin)
if not isinstance(d, list):
    print(json.dumps(d, indent=2)); sys.exit(1)
if not d:
    print("(no matching issues)"); sys.exit(0)
print("%-16s %5s %4s %-11s %-20s %s" % ("SHORT ID","EV","USR","SUBSTATUS","LAST SEEN","TITLE"))
for i in d:
    print("%-16s %5s %4s %-11s %-20s %s" % (
        i.get("shortId","?"), i.get("count",""), i.get("userCount",""),
        (i.get("substatus") or i.get("status") or ""),
        (i.get("lastSeen","") or "")[:19],
        (i.get("title","") or "")[:70]))
'
}

cmd_show() {  # show <shortId>
  [[ $# -ge 1 ]] || die "usage: show <shortId>"
  api GET "/organizations/$ORG/issues/$1/" | py '
import sys, json
d = json.load(sys.stdin)
fields = ["shortId","status","substatus","level","isUnhandled","count","userCount",
          "firstSeen","lastSeen","permalink"]
for f in fields:
    print("%-14s: %s" % (f, d.get(f)))
a = d.get("assignedTo")
print("%-14s: %s" % ("assignedTo", a.get("name") if isinstance(a, dict) else a))
'
}

cmd_event() {  # event <shortId> [latest|oldest|<eventId>]
  [[ $# -ge 1 ]] || die "usage: event <shortId> [latest|oldest|<eventId>]"
  local ref="${2:-latest}"
  api GET "/organizations/$ORG/issues/$1/events/$ref/" | py '
import sys, json
e = json.load(sys.stdin)
rel = e.get("release")
rel = rel.get("version") if isinstance(rel, dict) else rel
print("event      : %s" % e.get("id"))
print("release    : %s   dist(build): %s" % (rel, e.get("dist")))
print("dateCreated: %s" % e.get("dateCreated"))
tags = {t["key"]: t["value"] for t in e.get("tags", [])}
for k in ("level","environment","os","device","handled","mechanism","user"):
    if k in tags:
        print("tag.%-8s: %s" % (k, tags[k]))
for entry in e.get("entries", []):
    if entry.get("type") != "exception":
        continue
    for v in entry["data"].get("values", []):
        print("\nexception  : %s: %s" % (v.get("type"), v.get("value")))
        frames = (v.get("stacktrace") or {}).get("frames", []) or []
        print("stacktrace (oldest first; crash is last; [APP]=in-app):")
        for f in frames:
            mark = "APP" if f.get("inApp") else "   "
            loc = f.get("filename") or f.get("package") or "?"
            ln = f.get("lineNo")
            where = ("%s:%s" % (loc, ln)) if ln else loc
            print("  [%s] %s  (%s)" % (mark, f.get("function") or "<unknown>", where))
'
}

# --- mutations (need event:write) ---------------------------------------

_put_status() { api PUT "/organizations/$ORG/issues/$1/" "$2" >/dev/null && echo "ok: $1 -> ${3:-updated}"; }

cmd_resolve()      { [[ $# -ge 1 ]] || die "usage: resolve <shortId>";      _put_status "$1" '{"status":"resolved"}' "resolved"; }
cmd_resolve_next() { [[ $# -ge 1 ]] || die "usage: resolve-next <shortId>"; _put_status "$1" '{"status":"resolved","statusDetails":{"inNextRelease":true}}' "resolvedInNextRelease"; }
cmd_archive()      { [[ $# -ge 1 ]] || die "usage: archive <shortId>";      _put_status "$1" '{"status":"ignored"}' "archived (ignored)"; }
cmd_unresolve()    { [[ $# -ge 1 ]] || die "usage: unresolve <shortId>";    _put_status "$1" '{"status":"unresolved"}' "unresolved"; }

cmd_assign() {  # assign <shortId> <user:ID|team:ID|email>
  [[ $# -ge 2 ]] || die "usage: assign <shortId> <user:ID|team:ID|email>"
  api PUT "/organizations/$ORG/issues/$1/" "{\"assignedTo\":\"$2\"}" >/dev/null && echo "ok: $1 assigned to $2"
}

cmd_comment() {  # comment <shortId> <text...>
  [[ $# -ge 2 ]] || die "usage: comment <shortId> <text>"
  local id="$1"; shift
  local text="$*" body
  body="$(py 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text")"
  api POST "/organizations/$ORG/issues/$id/comments/" "$body" >/dev/null && echo "ok: comment added to $id"
}

usage() {
  cat >&2 <<'EOF'
sentry.sh — operate the codans Sentry project (org=thinking-function, project=apple-macos)

Read:
  list [query] [14d|24h|'']     list issues (default: is:unresolved, sort=freq)
  show <shortId>                issue status, counts, first/last seen, assignee
  event <shortId> [ref]         pretty-print an event's exception + stacktrace
                                ref = latest (default) | oldest | <eventId>

Mutate (need event:write):
  resolve <shortId>             mark resolved now
  resolve-next <shortId>        resolve in the next release (regression-tracked)
  archive <shortId>             archive / ignore (out of the default queue)
  unresolve <shortId>           reopen
  assign <shortId> <actor>      actor = user:<id> | team:<id> | <email>
  comment <shortId> <text>      add a note (audit trail; link the fixing PR)

Useful queries (the `is:` token does NOT accept `unhandled`):
  "is:unresolved error.unhandled:true"  unresolved crashes only
  "is:unresolved level:fatal"           fatal-level only
  "is:for_review"                        triage queue
  "release:codans@0.4.13"                bound to one release
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
sub="$1"; shift || true
case "$sub" in
  list)         cmd_list "$@";;
  show)         cmd_show "$@";;
  event)        cmd_event "$@";;
  resolve)      cmd_resolve "$@";;
  resolve-next) cmd_resolve_next "$@";;
  archive)      cmd_archive "$@";;
  unresolve)    cmd_unresolve "$@";;
  assign)       cmd_assign "$@";;
  comment)      cmd_comment "$@";;
  -h|--help|help) usage;;
  *) die "unknown command: $sub (try --help)";;
esac
