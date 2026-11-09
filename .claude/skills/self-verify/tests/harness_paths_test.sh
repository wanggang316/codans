#!/usr/bin/env bash
# Tests for the per-run socket and cache paths of cli-regression/harness.sh.
# Uses the `paths` phase, so it needs no Debug build and starts nothing.
#
# Usage: bash .claude/skills/self-verify/tests/harness_paths_test.sh

set -u

here="$(cd "$(dirname "$0")" && pwd)"
harness="$here/../cli-regression/harness.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sv-harness-paths-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
failures=0

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  failures=$((failures + 1))
}
expect() { # expect <name> <command...>
  if "${@:2}"; then pass "$1"; else fail "$1"; fi
}

# paths <session> <work dir> -> "<socket> <cache>"
paths() {
  SELF_VERIFY_SESSION="$1" CODANS_CLI_REGRESSION_DIR="$2" \
    bash "$harness" "$scratch/No.app" paths | awk -F= '{printf "%s ", $2} END {print ""}'
}

read -r sock_a cache_a <<<"$(paths s1 "$scratch/a")"
read -r sock_b cache_b <<<"$(paths s1 "$scratch/b")"
read -r sock_a2 cache_a2 <<<"$(paths s1 "$scratch/a")"
read -r sock_c cache_c <<<"$(paths s2 "$scratch/a")"

expect "paths phase prints a socket and a cache" test -n "$sock_a" -a -n "$cache_a"
expect "two runs of one session get distinct sockets" test "$sock_a" != "$sock_b"
expect "two runs of one session get distinct caches" test "$cache_a" != "$cache_b"
expect "one work dir keeps its paths (setup, then quit)" test "$sock_a $cache_a" = "$sock_a2 $cache_a2"
expect "two sessions on one work dir get distinct paths" test "$sock_a $cache_a" != "$sock_c $cache_c"
expect "the socket is not the old uid-only path" test "$sock_a" != "/tmp/codans-t-$(id -u).sock"
expect "the socket fits in 104 bytes" test "${#sock_a}" -lt 104
expect "a zmx socket (<cache>/run/<uuid>) fits in 104 bytes" test $((${#cache_a} + 41)) -lt 104

# The token is the self-verify session token of <work dir> and <session id>.
token="$(
  set +u
  . "$here/../scripts/helpers.sh"
  sv_session_token "$scratch/a" "s1"
)"
expect "the token comes from sv_session_token" test "$sock_a" = "/tmp/cdv-rg-$(id -u)-$token.sock"

if [ "$failures" -gt 0 ]; then
  printf '%s failure(s)\n' "$failures"
  exit 1
fi
printf 'all passed\n'
