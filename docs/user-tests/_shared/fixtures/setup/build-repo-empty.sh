#!/usr/bin/env bash
# Generator for the empty-repo fixture bundle used by UT-BSH-DV-005
# (History tab empty state). Produces `repo-empty.bundle`: a freshly
# `git init`'d repo with zero commits, zero branches with commits, no
# remotes.
#
# Usage:
#   bash build-repo-empty.sh [<output-dir>]
# Default output-dir is the parent fixtures/ directory.
#
# Caveat on `git bundle` and empty repos: `git bundle create --all` refuses
# to bundle a repo with no commits ("Refusing to create empty bundle"). We
# work around this with a single zero-byte sentinel commit on a throwaway
# branch `__fixture_seed__` that the restore script deletes after unbundle,
# leaving the consumer-visible state at "freshly initialised, no branches".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${1:-${FIXTURES_DIR}}"
mkdir -p "${OUT_DIR}"

BUNDLE_PATH="${OUT_DIR}/repo-empty.bundle"

export GIT_AUTHOR_NAME='Test'
export GIT_AUTHOR_EMAIL='test@example.com'
export GIT_COMMITTER_NAME='Test'
export GIT_COMMITTER_EMAIL='test@example.com'

BASE_EPOCH=1767225600  # 2026-01-01T00:00:00Z

WORK_DIR="$(mktemp -d -t codans-fixture-empty.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

REPO_DIR="${WORK_DIR}/repo"
git init -q -b main "${REPO_DIR}"
git -C "${REPO_DIR}" config user.name 'Test'
git -C "${REPO_DIR}" config user.email 'test@example.com'
git -C "${REPO_DIR}" config gc.auto 0

# Single seed commit on a throwaway branch so the bundle isn't empty.
# `restore-repo-empty.sh` removes this branch + the commit's reachability,
# leaving the consumer with a no-commit no-branch repo.
git -C "${REPO_DIR}" checkout -q -b __fixture_seed__
GIT_AUTHOR_DATE="${BASE_EPOCH} +0000" \
GIT_COMMITTER_DATE="${BASE_EPOCH} +0000" \
  git -C "${REPO_DIR}" commit -q --allow-empty -m "fixture seed (removed on restore)"

git -C "${REPO_DIR}" repack -q -a -d
git -C "${REPO_DIR}" gc -q --prune=now --quiet || true

git -C "${REPO_DIR}" bundle create -q "${BUNDLE_PATH}" --all

echo "Wrote: ${BUNDLE_PATH}"
ls -l "${BUNDLE_PATH}" | awk '{ printf "size: %s bytes\n", $5 }'
