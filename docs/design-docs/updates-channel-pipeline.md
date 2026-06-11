# Design Doc: Update channel — release pipeline

**Status:** Draft
**Author:** Gump
**Date:** 2026-05-08

## Context and Scope

The macOS app persists `GeneralSettings.updateChannel` (`stable` / `tip`) and the
`ChannelUpdaterDelegate` returns the right `allowedChannels(for:)` set so Sparkle
filters appcast items by channel. The release pipeline needs to actually produce items
on both channels for the in-app picker to do anything.

`SUFeedURL` in `Configurations/mac-Info.plist` points at
`https://github.com/wanggang316/codans/releases/latest/download/appcast.xml`. The
`releases/latest/...` redirect skips prereleases, so it always serves whatever the most
recent non-prerelease GitHub Release attached as `appcast.xml`.

## Goals and Non-Goals

**Goals**
- A user who selects Tip in Settings starts receiving pre-release builds within one
  Sparkle check cycle (≤ 1 h on tip).
- A user who stays on Stable never receives a tip build, even if a tip release is more
  recent.
- A tip user automatically follows Stable when no fresh tip exists (Sparkle picks the
  higher build number across allowed channels).
- Single feed URL — no per-channel SUFeedURL switching, no `feedURLString(for:)`. Channel
  filtering is purely client-side via `allowedChannels(for:)`.

**Non-Goals (v1)**
- Delta updates (`.delta` patches). Full DMG-per-update is fine for v1; deltas land later.
- `.app.zip` distribution unit. Sparkle accepts DMG enclosures; we keep the existing
  artifact and avoid double-building.
- Auto tip on every `main` push (supacode does this; codans is single-developer and
  too noisy). Tip is `workflow_dispatch` only.
- Per-architecture appcasts. universal binary today, Sparkle handles arch matching.

## Design

### Overview

Adopt the **supacode pattern**: one canonical `appcast.xml` lives as an asset on the
latest stable GitHub Release. The file contains items for **both** channels, distinguished
by `<sparkle:channel>` tags. Stable workflow regenerates this file on each `vX.Y.Z` push;
tip workflow regenerates the tip portion and merges it into the latest stable's
`appcast.xml`. Clients always read from `releases/latest/download/appcast.xml`; channel
selection happens entirely in `ChannelUpdaterDelegate.allowedChannels(for:)`.

Why this shape:

- **No new infrastructure** — reuses GitHub Releases and the existing `release.yml` auth
  path. No fixed-tag aggregator release, no GitHub Pages branch, no custom domain.
- **No client URL change** — current `SUFeedURL` already does the right thing because
  GitHub's `releases/latest/...` redirect skips prereleases, so it always serves the
  latest stable's `appcast.xml`.
- **Tip clients automatically follow stable** when no fresher tip exists, because Sparkle
  treats items with no `<sparkle:channel>` element as default-channel and always allows
  them. `allowedChannels = ["tip"]` is "default + tip", not "tip only".
- **Steady-state simplicity** — only two transitions to reason about: `stable cut`
  (overwrites appcast.xml with stable items only) and `tip cut` (merges tip items into
  the existing stable appcast).

### Tag conventions

| Pattern | Channel | GitHub Release flag | Created by |
|---|---|---|---|
| `vX.Y.Z` | stable | default (becomes `latest`) | human-driven `release` skill |
| `tip` (floating, force-moved every tip cut) | tip | `--prerelease` | `release-tip.yml` workflow_dispatch |

Tip never gets a versioned tag (no `vX.Y.Z-tip.N`). The `tip` tag is force-moved to the
HEAD commit of the workflow run on every successful tip cut, identical to ghostty's tip
release model.

### Build number scheme

| Channel | `MARKETING_VERSION` | `CURRENT_PROJECT_VERSION` |
|---|---|---|
| Stable | `X.Y.Z` (manually bumped) | `YYYYMMDDN` (date-based, current pattern) |
| Tip | inherited from current stable | `BASE * 1000 + github.run_number`, where `BASE` is the date-based build of the latest stable |

The tip build number formula is `int(stable_build) * 1000 + run_number`. With the
date-based stable scheme that means a tip after stable build `20260506` would be e.g.
`20260506000` for `run_number=0`, `20260506001` for run 1. This keeps tip builds strictly
greater than the stable they were cut from, but any subsequent stable bump (next day or
sequence-suffixed) is still greater than every tip in between.

`run_number` is bounded above by GitHub Actions' run sequence; the formula errors out if
it exceeds 999, forcing a stable bump (matches supacode's guard).

### Tip workflow flow (`.github/workflows/release-tip.yml`)

`workflow_dispatch` trigger; same secrets as stable.

1. Build the app with the elevated `CURRENT_PROJECT_VERSION` baked into a release
   xcconfig override.
2. Sign + notarize + staple (same path as stable).
3. Generate `appcast.xml` for THIS tip build only via
   `generate_appcast --channel tip --maximum-versions 1`. Sparkle stamps each item with
   `<sparkle:channel>tip</sparkle:channel>` automatically — no `sed` post-processing.
4. Force-move the `tip` git tag to `${{ github.sha }}`, push.
5. Create or update the `tip` GitHub Release with `--prerelease`, attach the DMG and the
   raw tip-only `appcast.xml`. The tip release exists primarily as a download surface and
   a tag anchor; clients never read its `appcast.xml` directly.
6. **Merge step** (the heart of the channel mechanism):
   - `gh release list --exclude-drafts --exclude-pre-releases` → latest stable tag.
   - `gh release download <stable_tag> -p appcast.xml` → fetch the canonical feed.
   - Python script: parse stable appcast XML, remove every `<item>` whose
     `<sparkle:channel>` is `tip`, append the fresh tip items, serialise back.
   - `gh release upload <stable_tag> appcast.xml --clobber` → push merged file back to
     the stable release.
7. Smoke check: `curl -fsSL releases/latest/download/appcast.xml` and grep for
   `<sparkle:channel>tip</sparkle:channel>`.

### Stable workflow flow (`.github/workflows/release.yml`)

Existing workflow continues unchanged for v1. The current `generate_appcast` invocation
already produces a 1-item appcast with the new DMG; that file becomes the new canonical
feed when the release is published. Tip items left over from the previous stable's
appcast are intentionally dropped — the next tip workflow run re-merges them in.

Two future-only annotations to add inline (no behavior change):

- A note that the file is the canonical feed read by every client regardless of channel.
- A note that tip-channel items are not preserved across stable releases by design;
  `release-tip.yml` repopulates them.

### Client changes

None for v1. `ChannelUpdaterDelegate.allowedChannels(for:)` already returns `[]` for
stable and `["tip"]` for tip, which is exactly what the supacode pattern expects from the
client. `SUFeedURL` is already correct.

The `feedURLString(for:)` delegate method explicitly should NOT be implemented — it would
add a second source of truth and break the "single feed" invariant.

### Bootstrap

First `release-tip.yml` run requires a successful stable release as a merge target.
Sequence:

1. Cut a normal stable release through the existing `release` skill (no pipeline change
   needed for this step).
2. Verify `releases/latest/download/appcast.xml` returns 200 and contains exactly one
   stable item.
3. Manually run the new `release-tip.yml` via `gh workflow run release-tip.yml`.
4. Verify the same URL now returns a feed with both a stable and a tip item.
5. Switch the in-app channel to Tip on a debug client + flush
   `defaults delete com.gumpw.codans`. Sparkle should offer the tip build.

## Open questions

- **Releasing a stable while a tip is pending** — both workflows share `concurrency: release`
  to serialise. If stable lands during a tip workflow's merge step, the merge picks up the
  fresh stable's appcast (which has no tip items yet), correctly re-injects the tip item,
  and uploads. No race. Document this in `release-tip.yml` comments.
- **Demoting from tip to stable client-side** — Sparkle re-prompts on every check, no
  built-in downgrade path. Documented as manual: switch channel in Settings, then delete
  `~/Library/Caches/Sparkle*` and reinstall the stable DMG. Out of scope for the pipeline.
- **Delta updates** — defer to a follow-up. Requires staging-dir scans of historical
  `.app.zip` archives plus a switch from DMG to zip distribution. Concrete enough that
  supacode's pattern transplants directly when we want it.
