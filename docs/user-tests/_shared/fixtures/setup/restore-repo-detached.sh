#!/usr/bin/env bash
# Restore the detached-HEAD fixture into <dest>. After restore, HEAD points
# at the third commit of main (detached state), all branches + remotes that
# the multi-branch bundle has are still present.
#
# Usage:
#   bash restore-repo-detached.sh <dest>

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dest>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_PATH="${FIXTURES_DIR}/repo-detached.bundle"
DEST="$1"

if [[ ! -f "${BUNDLE_PATH}" ]]; then
  echo "missing bundle: ${BUNDLE_PATH}" >&2
  echo "regenerate via: bash ${SCRIPT_DIR}/build-repo-detached.sh" >&2
  exit 1
fi

rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"

# init + fetch-with-explicit-refspecs (same pattern as
# restore-repo-multi-branch.sh) so the bundled refs/remotes/origin/*
# survive intact.
git init -q "${DEST}"
git -C "${DEST}" config user.name 'Test'
git -C "${DEST}" config user.email 'test@example.com'
git -C "${DEST}" symbolic-ref HEAD refs/heads/__bootstrap__
git -C "${DEST}" fetch -q "${BUNDLE_PATH}" \
  '+refs/heads/*:refs/heads/*' \
  '+refs/remotes/origin/*:refs/remotes/origin/*' >/dev/null

# Recompute the detach target (third commit of main, oldest-first) so
# this script is independent of any HEAD value that survived the bundle.
THIRD_SHA="$(git -C "${DEST}" log --reverse --format=%H main | sed -n '3p')"
if [[ -z "${THIRD_SHA}" ]]; then
  echo "restore-repo-detached: failed to resolve third commit of main" >&2
  exit 1
fi
git -C "${DEST}" checkout -q --detach "${THIRD_SHA}"

git -C "${DEST}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main || true

echo "Restored repo-detached -> ${DEST} (detached @ ${THIRD_SHA})"
