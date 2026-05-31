#!/usr/bin/env bash
# Restore the empty-repo fixture into <dest>. The bundle ships a single
# throwaway commit on branch `__fixture_seed__` (a `git bundle` quirk —
# it refuses to bundle a repo with zero commits); this script unbundles
# into a fresh `git init` and then removes the seed so the consumer sees
# a truly empty repo: zero commits, zero branches, zero remotes.
#
# Usage:
#   bash restore-repo-empty.sh <dest>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dest>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_PATH="${FIXTURES_DIR}/repo-empty.bundle"
DEST="$1"

if [[ ! -f "${BUNDLE_PATH}" ]]; then
  echo "missing bundle: ${BUNDLE_PATH}" >&2
  echo "regenerate via: bash ${SCRIPT_DIR}/build-repo-empty.sh" >&2
  exit 1
fi

rm -rf "${DEST}"
mkdir -p "${DEST}"

# Fresh init; default branch `main` matches the build-script choice.
git init -q -b main "${DEST}"
git -C "${DEST}" config user.name 'Test'
git -C "${DEST}" config user.email 'test@example.com'
# Pull the seed objects in (we don't strictly need them, but `bundle
# unbundle` is the documented contract; the seed branch is deleted next).
git -C "${DEST}" bundle unbundle "${BUNDLE_PATH}" >/dev/null
# Throw away the seed ref. After this:
#   - no branches (HEAD still points at refs/heads/main but that ref does
#     not exist yet => `git symbolic-ref --short HEAD` returns "main" while
#     `git rev-parse HEAD` errors out, which is the canonical "unborn HEAD"
#     state of a freshly init'd repo).
#   - no commits reachable from any ref.
git -C "${DEST}" update-ref -d refs/heads/__fixture_seed__ || true
# Sweep any unreachable objects so `git fsck` is clean.
git -C "${DEST}" reflog expire --expire=now --all
git -C "${DEST}" gc --prune=now --quiet || true

echo "Restored repo-empty -> ${DEST}"
