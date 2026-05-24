#!/usr/bin/env bash
# Restore the multi-branch fixture into <dest>. The test runner invokes this
# before each UT-BSH-* multi-branch case.
#
# Usage:
#   bash restore-repo-multi-branch.sh <dest>
#
# Post-conditions:
#   - <dest> is a freshly-cloned working tree of repo-multi-branch.bundle.
#   - HEAD is on feat/header-redesign.
#   - refs/remotes/origin/{main,feat/new-shell} and origin/HEAD -> origin/main
#     are present (the bundle ships them as remote-tracking refs).
#   - user.name/user.email are set so subsequent in-test commits don't fail.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dest>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_PATH="${FIXTURES_DIR}/repo-multi-branch.bundle"
DEST="$1"

if [[ ! -f "${BUNDLE_PATH}" ]]; then
  echo "missing bundle: ${BUNDLE_PATH}" >&2
  echo "regenerate via: bash ${SCRIPT_DIR}/build-repo-multi-branch.sh" >&2
  exit 1
fi

rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"

# We use `git init` + `git fetch <bundle>` with explicit refspecs rather
# than `git clone <bundle>`, because clone remaps the bundle's
# refs/heads/* into refs/remotes/origin/* (which would clobber the
# original refs/remotes/origin/* shipped inside the bundle —
# origin/main, origin/feat/new-shell). The explicit-refspec fetch path
# drops every bundled ref into the new repo verbatim.
git init -q "${DEST}"
git -C "${DEST}" config user.name 'Test'
git -C "${DEST}" config user.email 'test@example.com'
# Detach HEAD off the default-init branch so the fetch can write
# refs/heads/main without "refusing to fetch into branch checked out".
git -C "${DEST}" symbolic-ref HEAD refs/heads/__bootstrap__

# Two refspecs: one for refs/heads/* and one for refs/remotes/origin/*.
# Trailing `+` forces non-fast-forward updates (always-overwrite on
# restore re-run, though we just init'd so this is for safety).
git -C "${DEST}" fetch -q "${BUNDLE_PATH}" \
  '+refs/heads/*:refs/heads/*' \
  '+refs/remotes/origin/*:refs/remotes/origin/*' >/dev/null

# Point HEAD at feat/header-redesign and populate the working tree.
git -C "${DEST}" symbolic-ref HEAD refs/heads/feat/header-redesign
git -C "${DEST}" reset -q --hard

# origin/HEAD is a symbolic ref; the bundle stores it as a regular ref
# pointing at the same SHA as origin/main, so re-symlink it explicitly.
git -C "${DEST}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

echo "Restored repo-multi-branch -> ${DEST}"
