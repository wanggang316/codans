# Design Doc: Update channel — release & signing pipeline

**状态：** 已上线（可见）
**Author:** Gump

## Context and Scope

The macOS app persists `GeneralSettings.updateChannel` (`stable` / `tip`) and the
`ChannelUpdaterDelegate` returns the right `allowedChannels(for:)` set so Sparkle
filters appcast items by channel. This doc covers the release pipeline that produces
items on both channels, plus the Developer-ID signing, notarization, and CI wiring that
the GitHub Actions release workflows depend on.

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
- Headless, reproducible CI signing + notarization with no GUI Apple-ID login.

**Non-Goals**
- Delta updates (`.delta` patches). Full DMG-per-update is fine; deltas can land later.
- `.app.zip` distribution unit. Sparkle accepts DMG enclosures; we keep the existing
  artifact and avoid double-building.
- Auto tip on every `main` push (supacode does this; codans is single-developer and
  too noisy). Tip is `workflow_dispatch` only.
- Per-architecture appcasts. universal binary today, Sparkle handles arch matching.

## Design

### Overview — the single-feed invariant

Adopt the **supacode pattern**: one canonical `appcast.xml` lives as an asset on the
latest stable GitHub Release. **That single file carries items for *both* channels**,
distinguished by `<sparkle:channel>` tags. Stable workflow regenerates this file on each
`vX.Y.Z` push; tip workflow regenerates the tip portion and merges it into the latest
stable's `appcast.xml`. Clients always read from `releases/latest/download/appcast.xml`;
channel selection happens entirely in `ChannelUpdaterDelegate.allowedChannels(for:)`.

This is the load-bearing invariant for the whole pipeline: **one feed, two channels,
client-side filtering.** Why this shape:

- **No new infrastructure** — reuses GitHub Releases and the existing auth path. No
  fixed-tag aggregator release, no GitHub Pages branch, no custom domain.
- **No client URL change** — `SUFeedURL` already does the right thing because GitHub's
  `releases/latest/...` redirect skips prereleases, so it always serves the latest
  stable's `appcast.xml`.
- **Tip clients automatically follow stable** when no fresher tip exists, because Sparkle
  treats items with no `<sparkle:channel>` element as default-channel and always allows
  them. `allowedChannels = ["tip"]` is "default + tip", not "tip only".
- **Steady-state simplicity** — only two transitions to reason about: `stable cut`
  (overwrites appcast.xml with stable items only) and `tip cut` (merges tip items into
  the existing stable appcast).

The `feedURLString(for:)` delegate method **explicitly must NOT be implemented** — it
would add a second source of truth and break the single-feed invariant.

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
| Stable | `X.Y.Z` (manually bumped) | `YYYYMMDDN` (date-based) |
| Tip | inherited from current stable | `BASE * 1000 + github.run_number`, where `BASE` is the date-based build of the latest stable |

The tip build number formula is `int(stable_build) * 1000 + run_number`. With the
date-based stable scheme that means a tip after stable build `20260506` would be e.g.
`20260506000` for `run_number=0`, `20260506001` for run 1. This keeps tip builds strictly
greater than the stable they were cut from, while any subsequent stable bump (next day or
sequence-suffixed) is still greater than every tip in between. **tip-follows-stable**: the
tip version inherits `MARKETING_VERSION` from the current stable, so a tip is always
anchored to a real stable release.

`run_number` is bounded above by GitHub Actions' run sequence; the formula **errors out
if it exceeds 999, forcing a stable bump** (matches supacode's guard).

`CURRENT_PROJECT_VERSION` must **increment by 1 on every release even when
`MARKETING_VERSION` is unchanged** — Sparkle / macOS update plumbing keys on
strictly-increasing per-bundle build numbers. A reused build number is invisible to the
updater.

### Tip workflow flow (`.github/workflows/release-tip.yml`)

`workflow_dispatch` trigger only; same secrets as stable.

1. Build the app with the elevated `CURRENT_PROJECT_VERSION` baked into a release
   xcconfig override.
2. Sign + notarize + staple (same path as stable — see Signing below).
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

The stable `generate_appcast` invocation produces a 1-item appcast with the new DMG; that
file becomes the new canonical feed when the release is published. Tip items left over
from the previous stable's appcast are intentionally dropped — the next tip workflow run
re-merges them in. Two inline annotations document this for future readers (no behavior):

- The file is the canonical feed read by every client regardless of channel.
- Tip-channel items are not preserved across stable releases by design; `release-tip.yml`
  repopulates them.

### Signing — Developer-ID via command-line build settings

Developer-ID signing is passed as **xcodebuild command-line build settings**, not an
xcconfig, because command-line settings sit atop Xcode's resolution order and win
deterministically:

```
CODE_SIGN_STYLE=Manual
DEVELOPMENT_TEAM=<team-id>
CODE_SIGN_IDENTITY=<SHA-1 from `security find-identity`>
OTHER_CODE_SIGN_FLAGS=--timestamp
ARCHS=arm64
```

Command-line settings are used **instead of an `Release.xcconfig` + `#include?` +
`defaultSettings: .essential(excluding:)` layering**, which loses to Xcode's resolution
order. Resolve the identity's SHA-1 via `security find-identity`.

**Do NOT `xcodebuild -exportArchive` for Developer-ID.** Its `IDEDistributionMethodManager`
needs a GUI-logged-in Apple ID, which is impossible headless in CI. Instead, **copy the
signed `.app` straight out of the `.xcarchive`** — there is no `ExportOptions.plist`.

### Notarization

Notarization uses an **App Store Connect P8 API key** — the only credential that works
headless without 2FA (an Apple-ID + app-specific-password path still trips interactive
prompts). The base64-encoded key from CI secrets is decoded with:

```
tr -d ' \n\r\t' | base64 -D
```

The `tr` strip is mandatory: BSD `base64` (`-D`) rejects the CR/LF that CI dashboards
append when a secret is pasted. After notarization, staple the ticket to the `.app`.

### CI — Xcode pin & arch lock (reproducibility)

CI pins Xcode by writing `DEVELOPER_DIR=/Applications/Xcode_26.0.app/Contents/Developer`
to `$GITHUB_ENV` (**not** `xcode-select`, which is racy and global), and locks
`ARCHS=arm64`. Both are about **reproducibility — the same Xcode and arch locally and in
CI**:

- macos-26's *default* Xcode ships a `SwiftUICore.tbd` whose `allowed-clients` list
  excludes this app. An x86_64 link path auto-discovers that tbd and **fails to link**;
  pinning the matching Xcode avoids it.
- libghostty's static imgui is **arm64-only** anyway, so an x86_64 slice could never link
  even if the tbd allowed it. `ARCHS=arm64` makes the constraint explicit rather than
  emergent.

### Client changes

None. `ChannelUpdaterDelegate.allowedChannels(for:)` already returns `[]` for stable and
`["tip"]` for tip, which is exactly what the supacode pattern expects from the client.
`SUFeedURL` is already correct. (And again: `feedURLString(for:)` stays unimplemented.)

## Operational Notes

Behavior for the operational edge cases:

- **Releasing a stable while a tip is pending** — both workflows share
  `concurrency: release` to serialise. If stable lands during a tip workflow's merge step,
  the merge picks up the fresh stable's appcast (which has no tip items yet), correctly
  re-injects the tip item, and uploads. No race. Documented in `release-tip.yml` comments.
- **Demoting from tip to stable client-side** — Sparkle re-prompts on every check; no
  built-in downgrade path. Manual: switch channel in Settings, then delete
  `~/Library/Caches/Sparkle*` and reinstall the stable DMG. Out of scope for the pipeline.
- **Bootstrap** — the first `release-tip.yml` run requires a successful stable release as a
  merge target. Sequence: cut a stable release via the `release` skill → verify
  `releases/latest/download/appcast.xml` returns 200 with exactly one stable item → run
  `gh workflow run release-tip.yml` → verify the same URL now returns both a stable and a
  tip item.
- **Delta updates** — deferred. Requires staging-dir scans of historical `.app.zip`
  archives plus a switch from DMG to zip distribution; supacode's pattern transplants
  directly when wanted.

## References

- Channel client (`ChannelUpdaterDelegate.allowedChannels(for:)`): `apps/mac/codans/App/Clients/UpdatesEnvironment.swift`
- Channel type: `apps/mac/CodansCore/Settings/UpdateChannel.swift`
- Feed URL: `apps/mac/Configurations/mac-Info.plist` (`SUFeedURL`)
- Release skill / build-number bump: `release` skill
- Workflows: `.github/workflows/release.yml`, `.github/workflows/release-tip.yml`
