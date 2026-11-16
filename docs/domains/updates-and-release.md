# Updates and release

A user gets codans as a notarized DMG from a GitHub Release, directly or through the Homebrew cask, and the app then updates itself with Sparkle. This domain covers both halves: how the installed app finds and applies an update, and how a commit on `main` becomes a published build that the update check can see. Procedures (how to cut a release, how to set up the tap or the crash reporting service) are in the runbooks and in the `release` skill; this page holds the model and the rules they rely on.

## Scope and neighbors

- Build channels, the bundle id that Debug and Release share, and the roots: [Environment](environment.md).
- The Settings store and the Updates pane shell: [Settings](settings.md).
- The app menu, the command palette, and the sidebar toolbar that host the update entry points: [Main window](main-window.md), [Command palette](command-palette.md).
- Procedures: the `release` skill (`.claude/skills/release/SKILL.md`), [Homebrew runbook](../runbooks/homebrew.md), [Crash reporting runbook](../runbooks/crash-reporting.md).

## Update model

There is **one feed**. `SUFeedURL` is `releases/latest/download/appcast.xml` of this repository. GitHub resolves `latest` to the newest published release that is not a prerelease, so the feed is always the `appcast.xml` asset of the newest stable release. That one file holds items for both update channels:

| Channel | Appcast items | `allowedChannels` | Sees |
|---|---|---|---|
| Stable | no `<sparkle:channel>` tag | `[]` | stable items only |
| Tip | `<sparkle:channel>tip</sparkle:channel>` | `["tip"]` | stable and tip items |

Channel selection happens only on the client, in `ChannelUpdaterDelegate.allowedChannels(for:)`. Sparkle always allows items without a channel tag, so a Tip user who has no newer tip build gets the newer stable build. Sparkle selects by build number (`CFBundleVersion`), not by marketing version.

Rules:

- Do not implement `feedURLString(for:)` and do not switch feeds per channel. A second feed source breaks the single-feed model that the pipeline writes.
- Each published build, stable or tip, must have a build number greater than every earlier one, also when `MARKETING_VERSION` does not change. Otherwise Sparkle does not offer it.
- `appcast.xml` is written only by CI. Each item carries an EdDSA signature of its DMG, made with the private half of `SUPublicEDKey` in the Info.plist. Sparkle rejects an update whose signature does not match that key.

## Update settings

Four settings live in `general` of `settings.json`: the channel (`stable` by default), the check interval (24 hours by default), automatic checks (on), and automatic download and install (off; installs on the next relaunch). `settings.json` is the source of truth. `UpdatesClient.applyPreferences` copies the four values into the running `SPUUpdater`, and Sparkle then stores them in its own preferences in `UserDefaults`. Sparkle's copy is derived; nothing reads it back into settings.

- At launch the app applies the settings once. When automatic checks are on, it also starts one silent background check, because Sparkle's own timer waits for the last check date plus the interval and would miss a release published in between.
- Each later change of one of the four values applies them again, whatever wrote the change. When automatic checks are on, a change of channel or interval in the Updates pane also starts a background check, and so does turning automatic checks on.

Entry points that start a manual check: **Check for Updates…** in the app menu and in the command palette, the button in Settings › Updates, and the update reminder in the sidebar toolbar. The reminder shows when the last loaded appcast has a build newer than the running one on the active channel. It is computed from the appcast, not from Sparkle's state, so it stays visible after **Skip This Version** until the user installs the update.

### Debug builds

Only `BuildChannel.release` starts the updater (`UpdatesEnvironment.isEnabled`). In a Debug build the updater never starts, `applyPreferences` and the manual check do nothing, and the Updates pane shows "Development builds don't check for updates." with its controls disabled. The skip includes the preference copy: a Debug build has the same bundle id as the installed app, so writing Sparkle's `UserDefaults` from it changes the installed app's updater. See [Environment](environment.md).

## Release pipeline

```
 release PR (release/vX.Y.Z)            push to main
   bump + CHANGELOG section               |
        | merge                           v
        v                           release-tip.yml
 release-merge.yml                   check -> build, sign, notarize
   tag vX.Y.Z on merged commit            -> tip appcast (channel=tip)
   build:  release.yml                    -> move tag `tip`, prerelease `tip`
     archive, sign, notarize app          -> merge tip items into the
     DMG, notarize DMG, appcast              newest stable appcast.xml
     draft release
   publish: check 4 assets -> latest
   cask:   update-cask.yml -> homebrew-tap
```

### Stable release

A stable release is a release pull request from `release/vX.Y.Z`. The merge of that pull request is the only human gate; `release-merge.yml` does everything after it. Each step has a condition that the next step depends on:

1. **Version bump and notes.** The pull request sets `MARKETING_VERSION` with `bump-version.sh` (never by hand) and adds `## [X.Y.Z] - YYYY-MM-DD` to `CHANGELOG.md`. The contract is: tag `vX.Y.Z` ⇔ `MARKETING_VERSION = X.Y.Z` ⇔ a CHANGELOG section for `X.Y.Z`. The `tag` job checks all three and stops before it tags if one does not match.
2. **Tag.** The job pushes the annotated tag on the merged commit. A tag that exists on another commit stops the run; a tag on the same commit is accepted, so a re-run is safe.
3. **Build number.** `release.yml` assigns `CURRENT_PROJECT_VERSION` at build time from the published appcast: `YYYYMMDD` plus a sequence, one more than the highest build in the feed. The committed value is only a floor. The edit stays in the CI checkout.
4. **Archive and sign.** The archive is signed with Developer ID through `xcodebuild` command-line build settings, which win over any xcconfig that Tuist generates. The signed `.app` is copied out of the `.xcarchive`; `-exportArchive` is not used because it needs an Apple ID that is logged in to a GUI. An ad-hoc signature stops the script.
5. **Notarize.** The app, then the DMG, go to the Apple notary service with an App Store Connect API key (the only credential that works without a GUI or 2FA), and get the ticket stapled. Stapling changes the file, so the DMG's `.sha256` is written again after it.
6. **Appcast.** `generate_appcast` writes an appcast with one item for the new DMG, signed with the EdDSA key. CI then puts the CHANGELOG section into the item as Markdown, which Sparkle shows as the release notes.
7. **Draft and publish.** The draft release gets four assets: `Codans-X.Y.Z.dmg`, its `.sha256`, `Codans.dmg` (a fixed name, so `releases/latest/download/Codans.dmg` is a stable download link), and `appcast.xml`. The `publish` job publishes it as latest only when all four are present. Publishing is the moment the new feed goes live.
8. **Cask.** `update-cask.yml` downloads the DMG, compares it with the `.sha256`, renders `Casks/codans.rb` with the version and hash, and pushes it to the tap. It never moves the tap to an older version and skips `tip` and prereleases.

The tag push and the publish use `GITHUB_TOKEN`, which starts no other workflow. For this reason `release-merge.yml` calls `release.yml` and `update-cask.yml` with `workflow_call`. A tag pushed by hand still starts `release.yml`, but that path stops at a draft that a person must publish.

### Tip builds

Each push to `main` starts `release-tip.yml`. It builds, signs, and notarizes the same way, then makes a one-item appcast with the channel `tip`, force-moves the floating tag `tip`, and updates the single prerelease `tip`. It then downloads the newest stable release's `appcast.xml`, replaces its tip items with the new one, and uploads it again. Old assets on the `tip` release are deleted only after that merge, because until then the feed points at the previous tip DMG.

- A stable publish replaces `appcast.xml` with a file that has stable items only. Tip users see no tip build until the next tip run merges one in. This is intended.
- Tip items carry no release notes.
- Tip needs a stable release to merge into. Without one, the merge step warns and does nothing.

### Stable and tip together

Both channels take build numbers from the same feed, so the two must not compute one at the same time. `release-merge.yml` waits until no tip run is in flight before it tags. The tip check job skips while a stable run is in flight, and it skips the push that changes `MARKETING_VERSION`, because the stable release ships that commit. A skipped tip is built by the next push. Stable runs do not join the tip concurrency group: GitHub cancels a queued run when a newer one arrives, and a stable run must not be dropped.

### Build environment

CI selects Xcode 26.0 and builds only `arm64`. A newer default Xcode on the runner fails to link against `SwiftUICore`, and libghostty's static parts are `arm64` only. A local Release archive should use the same Xcode and architecture so that it reproduces CI.

## CHANGELOG

`CHANGELOG.md` follows Keep a Changelog: an `## [Unreleased]` section with the six category headings, then one `## [X.Y.Z] - YYYY-MM-DD` section per release. Pull requests add bullets to `[Unreleased]`; the release pull request rewrites them into the release section. That section is published text: it becomes the GitHub Release body and the release notes in Sparkle's update window. The `release` skill holds the writing rules.

## Crash reporting symbols

Between archive and notarization, `release.sh upload-symbols` registers the Sentry release `codans@<MARKETING_VERSION>` and uploads the dSYMs from the archive. The app uses the same release name at runtime, so the two must agree; tip builds of the same version upload to the same release. The step is idempotent, and it does nothing when the Sentry secrets are missing; the release still ships, but crash stacks are not symbolicated. CI also writes the Sentry DSN into the build before the archive; without it the build ships with crash reporting off. Setup and checks: [Crash reporting runbook](../runbooks/crash-reporting.md).

## Traps

- **A failed appcast lookup gives a low build number.** If CI cannot read the feed, the build number falls back to the committed floor or today's first number, which can be at or below a published build. Sparkle then does not offer the new build. Check the assigned number in the run log.
- **Do not edit or re-upload `appcast.xml` by hand.** Every client reads that one file, and the tip workflow merges into whatever is there, so a hand edit reaches all users and stays until the next stable release.
- **A published release that is broken is not removed.** Roll forward with a new version; the `release` skill describes the recovery for each failed job.
- **Switching from Tip to Stable does not downgrade.** Sparkle has no downgrade path. The user stays on the tip build until a stable build with a higher build number appears, or installs the stable DMG by hand.

## Implementation shape

On the app side, `UpdatesEnvironment` owns the one `SPUStandardUpdaterController`, the channel delegate, and the observable `UpdatesModel` that drives the sidebar reminder. `UpdatesClient` is the dependency that features call to apply settings and to check now. The channel and interval types are in `CodansCore/Settings/`. On the release side, `.github/workflows/` holds the four release workflows, `apps/mac/scripts/` holds `release.sh` (archive, notarize, DMG, symbol upload) and `bump-version.sh` (versions and build numbers), and `Casks/codans.rb` is the cask template.
