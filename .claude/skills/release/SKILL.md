---
name: release
description: Cut a codans stable release through a pull request. Write the release notes into CHANGELOG, pick the Semantic Versioning bump from them, bump MARKETING_VERSION, and open a release PR; merging it makes CI tag, build, notarize, publish the release, and update the Homebrew cask. Use when shipping a new stable build.
---

# release: Cut a codans stable release

A stable release is **a release PR**. The PR (head branch `release/vX.Y.Z`)
lands the version bump and the release notes on `main`. Its merge starts
`.github/workflows/release-merge.yml`, which tags the merged commit `vX.Y.Z`,
builds, signs, and notarizes through `release.yml`, assigns the build number,
publishes the GitHub Release with the DMG and the Sparkle `appcast.xml`, and
updates the Homebrew cask. **Merging the release PR ships the release.** The
contract CI enforces:

> tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` in
> `apps/mac/Configurations/Project.xcconfig` ⇔ `CHANGELOG.md` has
> `## [X.Y.Z] - YYYY-MM-DD`.

CI extracts that CHANGELOG section verbatim as the GitHub Release body and
Sparkle's "What's New" pane — it is published prose, not a work record.

Don't use this for fixing the release pipeline itself (no version bump).
Never push to `main` directly; every release change goes through a PR.

## Process

The release PR is the single gate. Run steps 1–6 without stopping: they
write only to a release branch and an open PR, which is the review surface.
After the user approves the merge in step 7, run steps 7–8 without stopping,
up to the published release.

### 1. Pre-flight

```bash
git status --porcelain                                 # empty
git fetch origin --tags
./apps/mac/scripts/bump-version.sh --print             # current version, next build, next patch / minor / major
```

Stop if the tree is dirty, a release PR is already open
(`gh pr list --search 'head:release/'`), or the target tag already exists.

### 2. Write the release notes

`[Unreleased]` is **input, not output**: it collects one bullet per PR, so a
single feature arrives with several bullets from different stages. Never
promote it as-is. Always cross-check it against
`git log --no-merges --pretty='%h %s' "$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)..origin/main"`
and keep only what a user can perceive.

**Consolidate.**
- One entry per user-visible surface (a feature area, the sidebar, a
  Settings pane, a CLI verb) per category, however many bullets it had.
- Describe the end state. Superseded work is dropped, not merged.
- Fold small polish on one area into a single bullet.
- A release reads as **3–8 entries**.

**Keep each entry to three lines** (~240 characters, as the file wraps): a
bold lead-in a skimming user can stop at, then at most two sentences.

```markdown
- **Detached-HEAD worktrees are named by their commit.** A worktree on
  no branch used to collapse onto its directory name — five rows all
  reading "codans"; the sidebar now captions it "Detached HEAD @<sha>".
```

To fit, cut internals, per-control tours, edge-case behavior, and flag
lists (name the CLI verb; leave flags to `--help`).

**Write for users.**
- Lead with what the user gets or the symptom that's gone, not the mechanism.
- Leave out engineering-only work (refactors, CI, lint, dependency bumps).
  Exceptions that are always listed: user-perceivable side effects
  (minimum-OS bump, faster startup) and anything deprecated, removed, or
  breaking.
- No commit prefixes, PR / issue numbers, hashes, type or module names, or
  protocol terms. Name the UI surface the user sees.

Categories follow Keep a Changelog 1.1.0: `Added`, `Changed`, `Deprecated`,
`Removed`, `Fixed`, `Security`.

### 3. Choose the version

Versions follow Semantic Versioning 2.0.0. Derive the bump from the notes of
step 2 — they are the user-visible change set — not from commit prefixes:

| The release contains | Bump |
|---|---|
| A breaking change: anything under `Removed`, or a `Changed` entry that breaks a CLI verb or flag, a settings / catalog / workflow file, or the skill contract | **major** — but **minor** while the version is `0.y.z` |
| Anything under `Added`, `Changed`, or `Deprecated` | **minor** |
| Only `Fixed` and `Security` | **patch** |

The highest row wins. Take the number from `bump-version.sh --print`. Never
bump to `1.0.0` on your own; going to 1.0 is the user's call.

This step is not a gate: state the version and the row that chose it, and go
on. The user corrects it in the PR if needed.

### 4. Branch, edit CHANGELOG, bump

```bash
git switch --no-track -c release/vX.Y.Z origin/main
```

`--no-track` matters: a branch started from `origin/main` otherwise tracks
`main`, and a bare `git push` would push to `main`.

In `CHANGELOG.md`, put the notes of step 2 under `## [X.Y.Z] - YYYY-MM-DD`
(today, local TZ), drop its empty categories, and reseed an empty
`## [Unreleased]` above it with all six headers. Then:

```bash
make mac-bump-version VERSION=X.Y.Z   # BUILD=N overrides the build number (rare)
```

The script owns `Project.xcconfig` — validates the version, writes
atomically, and syncs the CLI version string. Never hand-edit the file. The
build number it writes is only a local floor: CI assigns the shipped build
number when it builds.

Skip a local build; the PR check and the release pipeline build it.

### 5. Commit and push

Stage only the release files, in one commit, with no trailers:

```bash
git add CHANGELOG.md apps/mac/Configurations/Project.xcconfig \
  apps/mac/codans-cli/CodansCLI.swift
git commit -m "chore(release): bump to X.Y.Z"
git push -u origin release/vX.Y.Z
```

### 6. Open the release PR

```bash
gh pr create --base main --head release/vX.Y.Z \
  --title "chore(release): bump to X.Y.Z" --body-file - <<'EOF'
Release X.Y.Z: <bump> because <row of step 3>.

<the new CHANGELOG section, verbatim>

Merging this PR ships X.Y.Z: release-merge.yml tags the merged commit,
builds and notarizes it, publishes the release, and updates the Homebrew
cask.
EOF
```

Not a draft. No agent names in the title or body. Then wait for the
`pr-build` check: `gh pr checks <PR> --watch`.

### 7. Merge — the only gate

Report the PR URL, the version, and the check result, and wait for the user
to approve the merge (or to merge it themselves). Edits the user asks for go
onto the release branch as new commits. If `main` gained user-visible
changes since step 2, update the notes (and, if the bump row changed, the
version) before the merge.

```bash
gh pr merge <PR> --rebase
git push origin --delete release/vX.Y.Z
```

Rebase keeps the bump commit as is on `main`. Don't pass `--delete-branch`:
it fails when `main` is checked out in another worktree. Never tag by hand:
`release-merge.yml` tags the merged commit.

### 8. Follow the release run

```bash
RUN=$(gh run list --workflow=release-merge.yml --branch release/vX.Y.Z \
  --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN" --exit-status
gh release view vX.Y.Z --json url,isDraft
```

The run first waits for tip builds in flight (up to 60 minutes), then takes
about 30 minutes to build and notarize. It publishes the release only when
the build passed and all four assets exist (`Codans-X.Y.Z.dmg`, its
`.sha256`, `Codans.dmg`, `appcast.xml`); otherwise it leaves a draft and
fails. Report the release URL and the cask job result.

Then free the worktree for the next release:

```bash
git fetch origin
git switch --detach origin/main
git branch -D release/vX.Y.Z
```

## Recovery

Roll forward; never force-push `main` or rewrite its history. Fixes to
`main` go through a PR. Deleting a pushed tag needs explicit user approval.

| Symptom | Fix |
|---|---|
| `tag` job fails on version, CHANGELOG, or branch name | Nothing was tagged. Fix it in a new `release/vX.Y.Z` PR; its merge starts a new run. |
| `tag` job: tag exists at another commit | With approval, delete it (`git push origin :refs/tags/vX.Y.Z`), then `gh run rerun <RUN> --failed`. |
| Notarization or other transient failure in `build` | Delete the draft release if one exists, then `gh run rerun <RUN> --failed`. The `tag` job accepts the existing tag. |
| `publish` fails: an asset is missing | Delete the draft, then re-run all jobs (`gh run rerun <RUN>`) so `build` runs again. The `tag` job accepts the existing tag. |
| `cask` fails | `gh run rerun <RUN> --failed`, or `gh workflow run update-cask.yml -f tag=vX.Y.Z`. |
| Release PR closed without merge | Delete the branch; nothing was released. |
| CI is down and a release must ship | Fallback: push the annotated tag on the merged commit by hand (starts `release.yml`), then publish the draft by hand, which fires `update-cask.yml`. |
| Wrong version shipped | Supersede it with the next version. |
| Published release is broken | Mark its header `## [X.Y.Z] - YYYY-MM-DD [YANKED]` with a one-line reason; ship the fix as a new version. |

`appcast.xml` is written only by CI — never edit it by hand.
