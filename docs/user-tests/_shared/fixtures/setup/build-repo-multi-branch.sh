#!/usr/bin/env bash
# Generator for the multi-branch fixture bundle used by UT-BSH-* runtime
# probes. Produces a `repo-multi-branch.bundle` git-bundle file with:
#   - local branches: main, feat/header-redesign, bugfix/menu
#   - a synthetic "origin" remote with origin/main, origin/feat/new-shell,
#     and origin/HEAD -> origin/main
#   - 60 commits on main (so the History tab's 50-per-page first page fills
#     and a second page exists)
#   - HEAD checked out on feat/header-redesign
#   - README.md is committed differently on main vs feat/header-redesign
#     (UT-BSH-BP-008 dirty-tree switch-blocking conflict)
#
# Determinism: all author/committer name+email+date env vars are fixed,
# and every commit gets a synthetic monotonic timestamp derived from
# BASE_EPOCH. Same git version + same script => identical bundle bytes
# (verified by running the script twice and diffing the output).
#
# Usage:
#   bash build-repo-multi-branch.sh [<output-dir>]
# Default output-dir is the parent fixtures/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${1:-${FIXTURES_DIR}}"
mkdir -p "${OUT_DIR}"

BUNDLE_PATH="${OUT_DIR}/repo-multi-branch.bundle"

# Fixed identity for every commit + tag operation in this script.
export GIT_AUTHOR_NAME='Test'
export GIT_AUTHOR_EMAIL='test@example.com'
export GIT_COMMITTER_NAME='Test'
export GIT_COMMITTER_EMAIL='test@example.com'

# Deterministic monotonic commit timestamps. Each commit gets BASE_EPOCH + n.
BASE_EPOCH=1767225600  # 2026-01-01T00:00:00Z, fixed.

# Work in an isolated tmp dir; cleanup on exit.
WORK_DIR="$(mktemp -d -t touch-code-fixture-multi-branch.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

REPO_DIR="${WORK_DIR}/repo"
ORIGIN_DIR="${WORK_DIR}/origin.git"

# ---------- Build the would-be "origin" remote first ----------
#
# We construct it as a bare repo we will later add as a file:// remote, fetch
# from, and then DROP the local file path replacing it with the on-the-fly
# string "origin" so the bundled refs/remotes/origin/* survive teardown. The
# remote-tracking refs themselves are what consumers of the bundle read; the
# remote URL is only used to populate those refs during the build.

git init -q -b main "${ORIGIN_DIR}"
git -C "${ORIGIN_DIR}" config receive.denyCurrentBranch ignore
git -C "${ORIGIN_DIR}" config gc.auto 0

# Seed origin with main + feat/new-shell.
ORIGIN_WORK="${WORK_DIR}/origin-work"
git clone -q "${ORIGIN_DIR}" "${ORIGIN_WORK}"
git -C "${ORIGIN_WORK}" config user.name 'Test'
git -C "${ORIGIN_WORK}" config user.email 'test@example.com'
git -C "${ORIGIN_WORK}" config gc.auto 0

commit_in_origin() {
  # $1 = file, $2 = content (\n is interpreted), $3 = subject, $4 = epoch
  # offset.
  local file="$1" content="$2" subject="$3" offset="$4"
  mkdir -p "$(dirname "${ORIGIN_WORK}/${file}")"
  printf '%b' "${content}" > "${ORIGIN_WORK}/${file}"
  git -C "${ORIGIN_WORK}" add "${file}"
  GIT_AUTHOR_DATE="$((BASE_EPOCH + offset)) +0000" \
  GIT_COMMITTER_DATE="$((BASE_EPOCH + offset)) +0000" \
    git -C "${ORIGIN_WORK}" commit -q -m "${subject}"
}

commit_in_origin "README.md" "origin seed\n" "origin: initial commit" 0
commit_in_origin "origin-main.txt" "main file\n" "origin: main work" 1
git -C "${ORIGIN_WORK}" push -q origin main

git -C "${ORIGIN_WORK}" checkout -q -b feat/new-shell
commit_in_origin "shell.txt" "new shell\n" "origin: new shell work" 2
git -C "${ORIGIN_WORK}" push -q origin feat/new-shell

# Make sure origin/HEAD -> origin/main is set on the bare repo.
git -C "${ORIGIN_DIR}" symbolic-ref HEAD refs/heads/main

# ---------- Build the working repo ----------
git init -q -b main "${REPO_DIR}"
git -C "${REPO_DIR}" config user.name 'Test'
git -C "${REPO_DIR}" config user.email 'test@example.com'
git -C "${REPO_DIR}" config gc.auto 0

commit_in_repo() {
  # $1 = file, $2 = content (\n is interpreted), $3 = subject, $4 = epoch
  # offset.
  local file="$1" content="$2" subject="$3" offset="$4"
  mkdir -p "$(dirname "${REPO_DIR}/${file}")"
  printf '%b' "${content}" > "${REPO_DIR}/${file}"
  git -C "${REPO_DIR}" add "${file}"
  GIT_AUTHOR_DATE="$((BASE_EPOCH + offset)) +0000" \
  GIT_COMMITTER_DATE="$((BASE_EPOCH + offset)) +0000" \
    git -C "${REPO_DIR}" commit -q -m "${subject}"
}

# main: bootstrap commit + README "main version" + padding to reach >= 60.
commit_in_repo "README.md" "main version\n" "main: initial commit" 100
commit_in_repo "src/app.txt" "app v1\n" "main: add app stub" 101
commit_in_repo "src/util.txt" "util v1\n" "main: add util stub" 102

# Pad main with 57 more commits => 60 total on main.
PAD_FILE="src/pad.txt"
for i in $(seq 1 57); do
  printf 'pad line %d\n' "${i}" > "${REPO_DIR}/${PAD_FILE}"
  git -C "${REPO_DIR}" add "${PAD_FILE}"
  offset=$((200 + i))
  GIT_AUTHOR_DATE="$((BASE_EPOCH + offset)) +0000" \
  GIT_COMMITTER_DATE="$((BASE_EPOCH + offset)) +0000" \
    git -C "${REPO_DIR}" commit -q -m "main: pad commit ${i}"
done

# Branch: bugfix/menu off main (single trivial commit so it diverges).
git -C "${REPO_DIR}" checkout -q -b bugfix/menu main
commit_in_repo "src/menu.txt" "menu fix\n" "bugfix: fix menu" 400

# Branch: feat/header-redesign off main, with a diverging README.md so a
# switch back to main while README is dirty triggers the
# "would be overwritten" git error consumed by UT-BSH-BP-008.
git -C "${REPO_DIR}" checkout -q -b feat/header-redesign main
commit_in_repo "README.md" "feat/header-redesign version\n" \
  "feat/header-redesign: rewrite README" 500
commit_in_repo "src/header.txt" "header redesign\n" \
  "feat/header-redesign: scaffold header" 501

# ---------- Wire the origin remote into the working repo ----------
git -C "${REPO_DIR}" remote add origin "${ORIGIN_DIR}"
git -C "${REPO_DIR}" fetch -q origin
# origin/HEAD symbolic ref; some git versions need an explicit set.
git -C "${REPO_DIR}" remote set-head origin main

# Stay on feat/header-redesign (HEAD requirement for the fixture).
git -C "${REPO_DIR}" checkout -q feat/header-redesign

# Pack everything into a single deterministic packfile before bundling so the
# packfile's object order is invariant across runs (loose-object packing order
# is otherwise sensitive to filesystem iteration). `repack -a -d` discards the
# original packs and emits one fresh pack from the full object graph.
git -C "${REPO_DIR}" repack -q -a -d
# Run gc as well so any lingering loose objects are folded into the new pack;
# this keeps `bundle create --all` from including the same object twice
# across pack + loose forms.
git -C "${REPO_DIR}" gc -q --prune=now --quiet || true

# `--all` includes refs/heads/* and refs/remotes/*; HEAD is added explicitly
# so the bundle's restored HEAD points at feat/header-redesign.
git -C "${REPO_DIR}" bundle create -q "${BUNDLE_PATH}" --all HEAD

echo "Wrote: ${BUNDLE_PATH}"
ls -l "${BUNDLE_PATH}" | awk '{ printf "size: %s bytes\n", $5 }'
