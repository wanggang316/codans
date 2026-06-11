---
name: release
description: Cut a codans stable release. Bump MARKETING_VERSION in Project.xcconfig, promote CHANGELOG [Unreleased] to a dated version section, commit, tag vX.Y.Z, and push to trigger the GitHub Actions Developer-ID release pipeline. Use when shipping a new stable build.
---

# release: Cut a codans stable release

## Overview

A stable codans release is **a tag push**. The
`.github/workflows/release.yml` pipeline keys off `v*` tags: it builds,
signs (Developer ID), notarizes, generates a Sparkle-signed
`appcast.xml`, and drafts a GitHub Release with the DMG attached. CI
**fails loud** when the tag does not match `MARKETING_VERSION` in
`apps/mac/Configurations/Project.xcconfig`, so the release contract is:

> tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` ⇔ `CHANGELOG.md` has a
> `## [X.Y.Z] - YYYY-MM-DD` section.

This skill walks those three artifacts into alignment, commits, tags,
pushes, and verifies CI started.

## When to use

- Ready to ship a new developer build to GitHub Releases / Sparkle clients.
- `[Unreleased]` in `CHANGELOG.md` has user-visible entries that warrant a release.

**Don't use** for:
- Hot-fixing CI or the release pipeline itself (no version bump).
- Local-only experiments — never tag without intent to publish.

## Project facts (load before acting)

| Concern | Where it lives |
|---|---|
| Marketing version (semver) | `apps/mac/Configurations/Project.xcconfig` → `MARKETING_VERSION` |
| Build number | same file → `CURRENT_PROJECT_VERSION` (`YYYYMMDDNNN`, shared by stable and tip; `bump-version.sh` queries the published appcast and increments) |
| Bump tool | `apps/mac/scripts/bump-version.sh` (called by `make mac-bump-version`) |
| User-visible changelog | `CHANGELOG.md` (project root) — stable only; tip cuts do not touch CHANGELOG |
| Release CI | `.github/workflows/release.yml` (tag-triggered on `v*`) |
| Tag format | `vX.Y.Z` annotated |
| Distribution unit | DMG (notarized + stapled). Sparkle clients update from the same DMG. |
| Canonical Sparkle feed | `https://github.com/wanggang316/codans/releases/latest/download/appcast.xml` — always served from the most recent non-prerelease release |
| Past bump style | `chore(release): bump to X.Y.Z` (xcconfig only) |

`MARKETING_VERSION` is **not** strict SemVer pre-1.0 — every release is a
developer build (per `CHANGELOG.md` preamble). Default cadence is patch;
bump minor when behavior is materially different.

## Process

### 0. Pre-flight — refuse to proceed if any check fails

Run all checks in parallel via `Bash`:

```bash
git rev-parse --abbrev-ref HEAD          # must be 'main' (or confirm with user)
git status --porcelain                    # must be empty
git fetch origin --tags                   # quiet; just refresh
git rev-list --left-right --count HEAD...origin/main   # must be 0 0 (or 0 N if local-ahead is intentional)
git tag --sort=-creatordate | head -3     # show most recent tags
./apps/mac/scripts/bump-version.sh --print  # current MARKETING_VERSION + CURRENT_PROJECT_VERSION + suggested next patch
```

Bail with a clear message if any of these are wrong:
- Not on `main` and user hasn't approved an off-`main` release.
- Working tree dirty.
- Local diverged from `origin/main` in a way the user didn't intend.
- A tag for the proposed version already exists.

### 1. Decide the version — ask the user

1. Read current `MARKETING_VERSION` and the `## [Unreleased]` section of
   `CHANGELOG.md`.
2. Propose: **patch** by default (`0.1.3 → 0.1.4`).
3. Show the user a summary table:

   ```
   Current: 0.1.3 (build 20260510001)
   Next:    0.1.4 (build 20260511001)  <-- patch (default; build = next from appcast)
   Or:      0.2.0 (build 20260511001)  <-- minor (user-visible scope changed)

   Unreleased highlights:
     Added — Add Project picker can create new folders inline
     Added — Folder → git auto-promotion
     Changed — Worktree executing indicator on icon
     Fixed — ⌘⌫ guard for main worktree + sidebar focus
     Removed — Inline loading spinner
   ```

4. Wait for explicit confirmation of `X.Y.Z` and the new build number
   before proceeding. **Never invent a version silently.**

### 2. Verify the changelog has shippable content

If `[Unreleased]` is empty (or only contains category headers with no
entries), **stop**. Tell the user to run `/hs-changelog` first to
extract recent commits, then resume.

**Writing style — user-facing language.** The CHANGELOG follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/) —
"changelogs are *for humans*, not machines." Rewrite raw commit
messages; don't paste them.

Use the six standard categories with their intended meanings:

| Section | What goes here |
|---|---|
| `Added` | New features |
| `Changed` | Modifications to existing functionality (behavior, shortcuts, defaults) |
| `Deprecated` | Features announced for future removal — still works today |
| `Removed` | Features gone in this version |
| `Fixed` | Bug fixes |
| `Security` | Vulnerability fixes |

The rules below govern the bullets under those headers.

In priority order — when rules conflict, earlier ones win:

1. **Describe what the user gets.** Lead with the feature, outcome,
   or — for bugs — the symptom that's now gone. Skip the mechanism.
   - Good: "Tabs remember their color across restarts."
     "Pane no longer flickers when switching tabs with the sidebar floating."
   - Bad: "Persist `Tab.colorToken` to `CodansCore.TabState`."
     "Fix race in `PaneHostView` state-restoration."

2. **Clarity beats brevity.** Be concise once the entry is clear. If
   one extra clause is what makes it land, write the clause. Don't
   cut words just to be short. Cap each entry at one or two short
   lines — three lines means the entry is doing too much.

3. **Skip engineering-only changes.** Refactors, module renames, CI
   tweaks, lint rules, dependency bumps, build-script edits, internal
   abstractions — out. The git log is their home. Two exceptions
   override this rule:
   - **User-perceivable side effects** — minimum-OS bump,
     telemetry-policy shift, noticeably faster startup. List under
     `Changed` and describe the user impact, not the refactor.
   - **Deprecations, removals, and breaking changes — always
     listed**, even when the change feels purely engineering. Users
     who hit a removed feature, a renamed setting, or an incompatible
     file format must find it here, not in a stack trace.

4. **Drop developer jargon.** No commit prefixes (`feat:`, `fix:`),
   no PR / issue numbers, no commit hashes, no module or type names,
   no protocol terms (`EPIPE`, `O_NONBLOCK`, `WKWebView`). Refer to
   features by the UI surface the user sees ("Settings → Updates",
   "sidebar"). Swap jargon for plain phrasing — "an intermittent
   crash when reopening a project" beats "a non-deterministic crash
   on project reopen".

5. **Consolidate within a release.** If several commits chased the
   same bug or refined the same feature inside one cycle, fold them
   into one entry that names the end state — the reader doesn't need
   the debugging journey. Bundle many tiny polish items into one
   bullet ("Various tab-bar polish: smoother color sheet, snappier
   middle-click close, tidier overflow menu") instead of five
   near-identical micro-bullets.

Sanity check before finalizing each entry: *would a user who only
uses the app care about this line, and could they understand it?* If
either answer is "no", rewrite or drop.

### 3. Cut the changelog version section

Edit `CHANGELOG.md`:

1. Replace `## [Unreleased]` with two sections:
   - A fresh empty `## [Unreleased]` at top with all six standard
     headers (`Added / Changed / Deprecated / Removed / Fixed /
     Security`) but **leave them empty** — the next cycle fills them.
   - The previous `[Unreleased]` body promoted under
     `## [X.Y.Z] - YYYY-MM-DD` (today's date in the user's local TZ).
2. Show the diff to the user before writing.

### 4. Bump the version files

```bash
make mac-bump-version VERSION=X.Y.Z
# or, with an explicit build number override (rarely needed):
make mac-bump-version VERSION=X.Y.Z BUILD=N
```

The Makefile target wraps `apps/mac/scripts/bump-version.sh`, which:
- validates `X.Y.Z` semver format,
- refuses if the new marketing version isn't strictly greater than the current,
- queries the published appcast for the highest build number (both
  stable and tip), then increments by 1 (or starts at `YYYYMMDD001`
  for a new calendar day),
- writes via tmpfile + post-write verification (atomic),
- and the Makefile guard refuses to run if `apps/mac/Configurations`
  has uncommitted changes.

Do **not** hand-edit `Project.xcconfig` — the script is the rule.

CI rejects a tag whose version doesn't match `MARKETING_VERSION` —
this is the gate that prevents accidental tag pushes.

### 5. Optional build verification

Default: **skip** the build (CI will catch real problems and the
pipeline takes ~10–20 minutes locally). Run `make mac-check` (fast,
~10s) only if the user has unrelated lint debt and wants to be sure
the bump commit is clean.

Run a full local `make mac-build` only if explicitly requested.

### 6. Commit — only the two bumped files

Show the user the staged diff before committing.

```bash
git add CHANGELOG.md apps/mac/Configurations/Project.xcconfig
git status                  # confirm only those two files are staged
git diff --cached            # final eyeball
```

Commit message format (matches `c65abde`, `9e6e5a0`, `2748a1f`):

```
chore(release): bump to X.Y.Z
```

No body unless the release has unusual notes (e.g., schema break worth
flagging in `git log` independently of the changelog). **No
Co-Authored-By trailer** — see `~/.claude/.../memory/feedback_no_coauthor_in_commits.md`.

Use a HEREDOC for the message:

```bash
git commit -m "$(cat <<'EOF'
chore(release): bump to X.Y.Z
EOF
)"
```

### 7. Tag — annotated, with release highlights

```bash
git tag -a vX.Y.Z -m "$(cat <<'EOF'
vX.Y.Z

<one short paragraph summarizing the release in user-facing language;
pull from CHANGELOG — describe what's new/improved/fixed, not how>
EOF
)"
```

The annotated message ends up on the GitHub Release page. Use the
same user-facing language as the CHANGELOG — no implementation
details, no module names.

**Do not push yet.** Confirm with the user that the tag looks right
(`git show vX.Y.Z --stat`).

### 8. Push — commit first, tag second

```bash
git push origin main
git push origin vX.Y.Z       # triggers .github/workflows/release.yml
```

Push order matters: pushing the tag first races CI against a
not-yet-visible commit. The CI checks out by ref name (`tag ==
commit`), so the commit must be on the remote before the tag.

If the user wants to pre-flight without triggering CI, use
`workflow_dispatch` with an existing tag instead of pushing a new one
— but that's an escape hatch, not the default.

### 9. Verify CI started

```bash
gh run list --workflow=release.yml --limit 1
gh run watch                          # follow the active run, optional
# When green:
gh release view vX.Y.Z                # the draft release
```

Tell the user:
- CI status (queued / running / passed / failed).
- The release is **draft** — the release body is the CHANGELOG section
  for this version (CI extracts it automatically). The user still needs
  to publish it manually via the GitHub UI or
  `gh release edit vX.Y.Z --draft=false`.

If CI fails, **do not** delete the tag or force-push without explicit
user approval — diagnose first (`gh run view --log-failed`).

## Failure modes & recovery

| Symptom | Cause | Fix |
|---|---|---|
| CI step "Verify tag matches MARKETING_VERSION" red | xcconfig wasn't bumped, or tag was created before bump landed | Bump xcconfig in a new commit, delete & recreate tag (`git tag -d vX.Y.Z; git push origin :refs/tags/vX.Y.Z`) — confirm with user before deleting remote tag |
| Tag pushed without CHANGELOG section | Skipped step 3 | Add the section in a follow-up `docs(changelog): record vX.Y.Z` commit on `main`; do not retag |
| Notarization fails | Apple-side; secrets correct but build flagged | Check `gh run view --log-failed`, often transient — re-run via `workflow_dispatch` against the existing tag |
| Wrong version pushed | Bumped to e.g. 0.2.0 when user wanted 0.1.4 | Roll forward only — pull next version, supersede with a new tag. Do not rewrite history on `main`. |
| Published release turns out broken / unsafe | Bug or signing/notarization issue surfaces after the draft was published | Mark the version YANKED instead of deleting it (Keep a Changelog 1.1.0). Edit `CHANGELOG.md` so the header becomes `## [X.Y.Z] - YYYY-MM-DD [YANKED]` and add a brief reason; commit on `main`. The `[YANKED]` tag is intentionally loud so users on that build notice. Cut a follow-up version with the actual fix. |

## Verification checklist

Before reporting "done":

- [ ] `git tag --sort=-creatordate | head -1` shows the new tag.
- [ ] `git log -1 --oneline origin/main` shows `chore(release): bump to X.Y.Z`.
- [ ] `awk -F'=' '/^MARKETING_VERSION/ ...' apps/mac/Configurations/Project.xcconfig` matches the tag.
- [ ] `CHANGELOG.md` has `## [X.Y.Z] - YYYY-MM-DD` with non-empty body and a fresh empty `## [Unreleased]` above.
- [ ] `gh run list --workflow=release.yml --limit 1` shows a queued or running job.
- [ ] User informed the GitHub Release will land as **draft** and needs manual publish.

## Anti-patterns

- ❌ Bumping `MARKETING_VERSION` and `CHANGELOG.md` in separate commits — pre-1.0 we keep the bump atomic.
- ❌ `git add -A` / `git add -u` — only stage the release files.
- ❌ Co-Authored-By trailer on the bump commit.
- ❌ Lightweight tag (`git tag vX.Y.Z`) — always annotated.
- ❌ Pushing tag before commit.
- ❌ Auto-publishing the GitHub Release — leave it draft for human review.
- ❌ Force-pushing `main` to "fix" a bad bump — roll forward instead.
- ❌ Hand-editing `appcast.xml` — the CI pipelines are the only writer.
