#!/usr/bin/env bash
#
# clean-merged-branches.sh — delete remote branches whose PR is already merged.
#
# "Merged" is judged by GitHub PR state (via `gh`), NOT by `git branch --merged`.
# This is deliberate: this repo squash-merges PRs, so a merged branch's commits
# never enter main's history and `git branch --merged` would miss them entirely.
# Querying the PR state catches squash-, rebase-, and merge-commit merges alike.
#
# Safe by default: it prints the branches it *would* delete and stops. Deleting a
# remote branch is hard to undo, so the actual `git push --delete` only runs with
# an explicit --yes.
#
# Usage:
#   ./scripts/clean-merged-branches.sh [options]
#
#   -y, --yes              Actually delete (default: dry-run, delete nothing)
#   -r, --remote <name>    Remote to clean (default: origin)
#   -p, --protect <csv>    Extra branch names to never delete (comma-separated)
#       --no-fetch         Skip the initial `git fetch --prune`
#   -h, --help             Show this help
#
# Examples:
#   ./scripts/clean-merged-branches.sh                 # preview only
#   ./scripts/clean-merged-branches.sh --yes           # delete for real
#   ./scripts/clean-merged-branches.sh -p staging,qa   # protect extra branches
#
# Requires: git, gh (authenticated — see `gh auth status`).

set -euo pipefail

REMOTE="origin"
DO_DELETE=0
DO_FETCH=1
EXTRA_PROTECT=""
# Upper bound on merged PRs fetched in one shot. Large enough for any realistic
# repo; if a repo ever exceeds it we warn rather than silently truncate.
PR_LIMIT=2000

die() { echo "clean-merged-branches: $*" >&2; exit 1; }

usage() {
  # Reprint the header comment block (lines between the shebang and `set -e`).
  sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)      DO_DELETE=1; shift ;;
    -r|--remote)   REMOTE="${2:?--remote needs a value}"; shift 2 ;;
    -p|--protect)  EXTRA_PROTECT="${2:?--protect needs a value}"; shift 2 ;;
    --no-fetch)    DO_FETCH=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
done

# --- Preflight -------------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git work tree"
command -v gh >/dev/null 2>&1 \
  || die "gh not found — install GitHub CLI (https://cli.github.com)"
gh auth status >/dev/null 2>&1 \
  || die "gh not authenticated — run: gh auth login"
git remote get-url "$REMOTE" >/dev/null 2>&1 \
  || die "no such remote: $REMOTE"

if [[ $DO_FETCH -eq 1 ]]; then
  echo "Fetching $REMOTE (prune)..."
  git fetch --prune "$REMOTE"
fi

# --- Gather facts ----------------------------------------------------------
# Owner of the current repo: used to drop head branches that live in forks,
# which carry the same headRefName but are not branches on our remote.
owner="$(gh repo view --json owner --jq '.owner.login')"
default_branch="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')"
current_branch="$(git symbolic-ref --quiet --short HEAD || true)"

# Head branch names of merged PRs in this repo (one per line, same-repo only).
merged_heads="$(gh pr list --state merged --limit "$PR_LIMIT" \
  --json headRefName,headRepositoryOwner \
  --jq ".[] | select(.headRepositoryOwner.login == \"${owner}\") | .headRefName")"

if [[ "$(printf '%s\n' "$merged_heads" | grep -c .)" -ge "$PR_LIMIT" ]]; then
  echo "warning: hit the $PR_LIMIT merged-PR cap; some merged branches may be" >&2
  echo "         missed. Raise PR_LIMIT in this script if your repo is larger." >&2
fi

# Newline-delimited protected set. Using grep -Fxq for membership keeps us clear
# of bash 3.2's empty-array-under-`set -u` pitfall (macOS ships bash 3.2).
protected="$(printf '%s\n' main master develop "$default_branch" "$current_branch" \
  | grep -v '^$' | sort -u)"
if [[ -n "$EXTRA_PROTECT" ]]; then
  protected="$(printf '%s\n%s\n' "$protected" "$(printf '%s' "$EXTRA_PROTECT" | tr ',' '\n')" \
    | grep -v '^$' | sort -u)"
fi

is_merged()    { printf '%s\n' "$merged_heads" | grep -Fxq -- "$1"; }
is_protected() { printf '%s\n' "$protected"    | grep -Fxq -- "$1"; }

# --- Match remote branches against merged PRs ------------------------------
to_delete=()
while IFS= read -r branch; do
  [[ -z "$branch" ]] && continue
  is_protected "$branch" && continue
  is_merged "$branch" || continue
  to_delete+=("$branch")
done < <(git branch -r --format='%(refname:short)' \
  | sed -n "s#^${REMOTE}/##p" \
  | grep -v '^HEAD$')

if [[ ${#to_delete[@]} -eq 0 ]]; then
  echo "Nothing to delete: no merged-PR branches on '$REMOTE'."
  exit 0
fi

echo
echo "Merged-PR branches on '$REMOTE' (${#to_delete[@]}):"
printf '  %s\n' "${to_delete[@]}"

if [[ $DO_DELETE -ne 1 ]]; then
  echo
  echo "Dry-run — nothing deleted. Re-run with --yes to delete the above."
  exit 0
fi

# --- Delete ----------------------------------------------------------------
echo
failed=0
for branch in "${to_delete[@]}"; do
  echo "Deleting ${REMOTE}/${branch}..."
  if ! git push "$REMOTE" --delete "$branch"; then
    echo "  failed to delete ${REMOTE}/${branch}" >&2
    failed=$((failed + 1))
  fi
done

if [[ $failed -gt 0 ]]; then
  die "$failed branch(es) failed to delete"
fi
echo "Done — deleted ${#to_delete[@]} branch(es)."
