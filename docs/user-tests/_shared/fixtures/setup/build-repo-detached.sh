#!/usr/bin/env bash
# Generator for the detached-HEAD fixture bundle used by UT-BSH-HD-003.
# Reuses the multi-branch generator, then detaches HEAD onto the third
# commit of main (chronologically: the third commit reachable from refs/
# heads/main when walked oldest-first) before re-bundling.
#
# Usage:
#   bash build-repo-detached.sh [<output-dir>]
# Default output-dir is the parent fixtures/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${1:-${FIXTURES_DIR}}"
mkdir -p "${OUT_DIR}"

BUNDLE_PATH="${OUT_DIR}/repo-detached.bundle"

WORK_DIR="$(mktemp -d -t codans-fixture-detached.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# 1. Build the multi-branch bundle into the tmp dir, then unbundle it
#    into a working repo so we can mutate HEAD.
bash "${SCRIPT_DIR}/build-repo-multi-branch.sh" "${WORK_DIR}" >/dev/null

REPO_DIR="${WORK_DIR}/repo"
# Mirror the restore script's approach: init + fetch-with-explicit-refspecs
# so the bundled refs/remotes/origin/* survive (clone would clobber them).
git init -q "${REPO_DIR}"
git -C "${REPO_DIR}" config user.name 'Test'
git -C "${REPO_DIR}" config user.email 'test@example.com'
git -C "${REPO_DIR}" config gc.auto 0
git -C "${REPO_DIR}" symbolic-ref HEAD refs/heads/__bootstrap__
git -C "${REPO_DIR}" fetch -q "${WORK_DIR}/repo-multi-branch.bundle" \
  '+refs/heads/*:refs/heads/*' \
  '+refs/remotes/origin/*:refs/remotes/origin/*' >/dev/null

# `git log --reverse main` lists main's commits oldest-first; the third
# entry is the deterministic "third commit on main".
THIRD_SHA="$(git -C "${REPO_DIR}" log --reverse --format=%H main | sed -n '3p')"
if [[ -z "${THIRD_SHA}" ]]; then
  echo "build-repo-detached: failed to resolve third commit on main" >&2
  exit 1
fi
git -C "${REPO_DIR}" checkout -q --detach "${THIRD_SHA}"

# Repack once more so the bundled packfile is stable.
git -C "${REPO_DIR}" repack -q -a -d
git -C "${REPO_DIR}" gc -q --prune=now --quiet || true

git -C "${REPO_DIR}" bundle create -q "${BUNDLE_PATH}" --all HEAD

echo "Wrote: ${BUNDLE_PATH}"
echo "Detached at: ${THIRD_SHA}"
ls -l "${BUNDLE_PATH}" | awk '{ printf "size: %s bytes\n", $5 }'
