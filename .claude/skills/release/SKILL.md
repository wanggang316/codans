---
name: release
description: Cut a codans stable release. Bump MARKETING_VERSION in Project.xcconfig, promote CHANGELOG [Unreleased] to a dated version section, commit, tag vX.Y.Z, and push to trigger the GitHub Actions Developer-ID release pipeline. Use when shipping a new stable build.
---

# release: Cut a codans stable release

A stable release is **a tag push**. `.github/workflows/release.yml` fires on
`v*` tags: it builds, signs, notarizes, writes a Sparkle `appcast.xml`, and
opens a **draft** GitHub Release with the DMG. The contract CI enforces:

> tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` in
> `apps/mac/Configurations/Project.xcconfig` ⇔ `CHANGELOG.md` has
> `## [X.Y.Z] - YYYY-MM-DD`.

CI extracts that CHANGELOG section verbatim as the GitHub Release body and
Sparkle's "What's New" pane — it is published prose, not a work record.

Don't use this for fixing the release pipeline itself (no version bump).

## Process

Every step that writes — CHANGELOG, commit, tag, push — shows the user the
result and waits for confirmation first.

### 1. Pre-flight

```bash
git rev-parse --abbrev-ref HEAD                        # main
git status --porcelain                                 # empty
git fetch origin --tags
git rev-list --left-right --count HEAD...origin/main   # 0 0
./apps/mac/scripts/bump-version.sh --print             # current version, build, suggested next
```

Stop if not on `main` (unless the user approves), the tree is dirty, local
has diverged from `origin/main`, or the target tag already exists.

### 2. Choose the version

Default to **patch**; propose **minor** when behavior changed materially.
Releases are pre-1.0 developer builds, not strict SemVer. Show current →
proposed version and build, and get explicit confirmation. Never pick a
version silently.

### 3. Write the release notes

`[Unreleased]` is **input, not output**: it collects one bullet per PR, so a
single feature arrives with several bullets from different stages. Never
promote it as-is. If it is empty, start from
`git log --no-merges --pretty='%h %s' "$(git describe --tags --abbrev=0)..HEAD"`
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

Then edit `CHANGELOG.md`: put the rewritten notes under
`## [X.Y.Z] - YYYY-MM-DD` (today, local TZ), drop its empty categories, and
reseed an empty `## [Unreleased]` above it with all six headers.

### 4. Bump the version

```bash
make mac-bump-version VERSION=X.Y.Z   # BUILD=N overrides the build number (rare)
```

The script owns `Project.xcconfig` — validates the version, takes the next
build number from the published appcast, writes atomically. Never hand-edit
the file.

Skip a local build by default; CI builds. Run `make mac-build` only if
asked.

### 5. Commit and tag

Stage only the two release files, in one commit, with no trailers:

```bash
git add CHANGELOG.md apps/mac/Configurations/Project.xcconfig
git commit -m "chore(release): bump to X.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
```

Always an annotated tag. Its message is only CI's fallback when the
CHANGELOG section is missing.

### 6. Push — commit first, then tag

```bash
git push origin main
git push origin vX.Y.Z   # triggers release.yml
```

The tag must not reach the remote before the commit it points at.

### 7. Confirm CI started

```bash
gh run list --workflow=release.yml --limit 1
```

Report the run status and remind the user the release is a **draft** to
publish by hand (`gh release edit vX.Y.Z --draft=false`). Never publish it
yourself.

## Recovery

Roll forward; never force-push `main` or rewrite its history. Deleting a
pushed tag needs explicit user approval.

| Symptom | Fix |
|---|---|
| CI: tag ≠ `MARKETING_VERSION` | Bump in a new commit, then — with approval — delete and recreate the tag (`git tag -d vX.Y.Z; git push origin :refs/tags/vX.Y.Z`). |
| Tag pushed without a CHANGELOG section | Add it in a `docs(changelog): record vX.Y.Z` commit on `main`; don't retag. |
| Notarization or other transient CI failure | `gh run view --log-failed`, then re-run via `workflow_dispatch` on the existing tag. |
| Wrong version shipped | Supersede it with the next version. |
| Published release is broken | Mark its header `## [X.Y.Z] - YYYY-MM-DD [YANKED]` with a one-line reason; ship the fix as a new version. |

`appcast.xml` is written only by CI — never edit it by hand.
