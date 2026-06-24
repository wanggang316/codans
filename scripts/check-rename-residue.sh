#!/usr/bin/env bash
#
# check-rename-residue.sh — guard against the Project Settings rename regressing.
#
# The Settings subtree refactor replaced specific `Repository*` identifiers with
# `Project*`. A rebase or sloppy find-and-replace can re-introduce the old names;
# this script catches those regressions by scanning for a concrete deny-list of
# symbols that must never reappear. Generic "Repository" / "repositories" tokens
# are **not** gated — they remain legitimately in:
#   - migration code describing the v2 → v3 move (`LegacyV2Settings`, decoder
#     comments referencing the old JSON key, ProjectSettings docstrings that
#     explain the rename)
#   - GitHub wire types (`headRepositoryOwner`, `repository { … }` query subsets)
#   - git-repository concept references in GitViewer / sidebar
#
# Usage: `./scripts/check-rename-residue.sh` (no args; defaults to `apps/mac/`).
#
# Exit 0 when the tree is clean. Exit 1 and print offending lines otherwise.

set -euo pipefail

ROOT="${1:-apps/mac}"

if [[ ! -d "$ROOT" ]]; then
  echo "check-rename-residue: no such directory '$ROOT'" >&2
  exit 2
fi

# Deny-list: identifiers that the Project Settings refactor retired. The presence
# of any of these is a hard-fail. Anchored with `\b` so partial matches
# (e.g. `LegacyV2RepositorySettings`, which is legitimate) do not trip the gate.
DENYLIST=(
  '\bRepositorySettings\b'
  '\bRepositorySettingsFeature\b'
  '\brepositoryPanes\b'
  '\bsetRepositoryDefaultEditor\b'
  '\bsetRepositoryWorktreeBaseDirectory\b'
  '\brepositoryGeneral\b'
  '\brepositoryHooks\b'
  '\bmutateRepository\b'
  # Retired per-Project sub-pane scaffolds; the General pane now absorbs their
  # content via Section-level conditional rendering. Must not reappear.
  '\bProjectGitSettingsView\b'
  '\bProjectGitHubSettingsView\b'
  '\bProjectEnvSettingsView\b'
)

PATTERN="$(IFS='|'; echo "${DENYLIST[*]}")"

# Emits `path:line:content`. The second filter drops hits that live inside Swift
# comments — `//…` line comments, `///` doc comments, and `*`-prefixed block-comment
# bodies. Historical notes that reference the old names are expected in comments;
# the gate only fires on code.
HITS=$(grep -rnIE "$PATTERN" "$ROOT" \
  --include='*.swift' \
  --exclude-dir='.build' \
  --exclude-dir='Tuist' \
  --exclude-dir='Derived' \
  --exclude-dir='ThirdParty' \
  | grep -vE ':\s*(//|///|\*)' \
  || true)

if [[ -n "$HITS" ]]; then
  echo "check-rename-residue: retired Project-Settings identifier(s) found:" >&2
  echo "$HITS" >&2
  echo >&2
  echo "Rename retired RepositorySettings identifiers to the Project* equivalent." >&2
  echo "Only LegacyV2RepositorySettings is allowed" >&2
  echo "to carry the RepositorySettings word, and only inside SettingsMigration." >&2
  exit 1
fi

echo "check-rename-residue: clean"
