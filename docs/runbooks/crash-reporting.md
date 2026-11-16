# Crash reporting

Release builds of codans report uncaught crashes (Mach exceptions, POSIX signals, `NSException`) and Swift errors to Sentry. The stacks are symbolicated with the dSYMs of the same archive. This runbook sets up the Sentry project, the build, and CI, and checks that a release reports symbolicated crashes. Where symbol upload sits in the release pipeline: [Updates and release](../domains/updates-and-release.md#crash-reporting-symbols).

## Context

- Debug builds never start the SDK. A release build starts it once, at app launch, only when **Settings › General › Send crash reports** is on (the default) and the Info.plist `SentryDSN` is a real DSN. A change of the toggle takes effect at the next launch.
- Turning the toggle off also deletes the per-install random identifier (`UserDefaults` key `com.gumpw.codans.install-id`), so a later report cannot be joined to earlier ones. `sendDefaultPii` is off.
- The runtime release name is `codans@<MARKETING_VERSION>`. `release.sh upload-symbols` registers the same name, so the dSYMs attach to the right release.
- `SystemHangFilter` drops events whose frames are all in a list of known macOS noise (`systemNoiseSignatures`). To silence a new false positive, add its signature there and ship a release.
- Sentry calls `beforeSend` off the main actor, but the app target defaults to `MainActor` isolation. Mark every off-main SDK callback and the types it captures `nonisolated`.

## Prerequisites

- Access to the Sentry organization, and permission to set repository secrets (`gh secret set`).
- `sentry-cli` (pinned in `mise.toml`; `release.sh` also accepts one on `PATH`).

## Set up

1. **Create the Sentry project** and copy its DSN. The DSN is not a secret, but keep it out of logs.

2. **Create an auth token** with the scopes `project:read`, `project:write`, `project:releases`. For local use, put it in `~/.sentryclirc`:

   ```ini
   [auth]
   token=sntryu_xxxxxxxx

   [defaults]
   org=<org-slug>
   project=<project-slug>
   url=https://sentry.io/
   ```

3. **Add the DSN to local release builds.** `mac-Info.plist` composes `SentryDSN` as `https://$(SENTRY_DSN_REST)`, because xcconfig reads `//` as a comment. Put only the part after `https://` in the gitignored `Secrets.xcconfig`:

   ```bash
   cp apps/mac/Configurations/Secrets.xcconfig.template \
      apps/mac/Configurations/Secrets.xcconfig
   $EDITOR apps/mac/Configurations/Secrets.xcconfig    # set SENTRY_DSN_REST
   git status -- apps/mac/Configurations/Secrets.xcconfig  # must show nothing
   ```

   Without this file the DSN is the bare `https://`, and the app does not start the SDK.

4. **Add the CI secrets.** `release.yml` and `release-tip.yml` write `Secrets.xcconfig` from `SENTRY_DSN_REST` before the archive, and run `release.sh upload-symbols` with the other three after it:

   ```bash
   gh secret set SENTRY_DSN_REST --body '<key>@<org-host>/<project-id>'   # DSN without https://
   gh secret set SENTRY_AUTH_TOKEN --body 'sntryu_xxxxxxxx'
   gh secret set SENTRY_ORG --body '<org-slug>'
   gh secret set SENTRY_PROJECT --body '<project-slug>'
   ```

   Each secret is optional for the pipeline: without `SENTRY_DSN_REST` the build ships with crash reporting off (CI logs a warning); without any of the other three the symbol upload is skipped.

## Upload symbols by hand

`release.sh release` runs `upload-symbols` between archive and notarization. To run it alone on an existing archive (`apps/mac/.build/release/Codans.xcarchive`):

```bash
SENTRY_AUTH_TOKEN=... SENTRY_ORG=<org-slug> SENTRY_PROJECT=<project-slug> \
  apps/mac/scripts/release.sh upload-symbols
```

The step is idempotent: it is safe to run again for the same release. If the token, the org, the project, or `sentry-cli` is missing, it logs the reason and exits 0.

## Check the result

1. In the release run log, the `Upload dSYMs to Sentry` step ends with `Sentry release codans@<version> ready`, not with a `skipping` line.
2. The Sentry dashboard shows the release `codans@<MARKETING_VERSION>` with the dSYMs attached.
3. Make a test crash in a release build. The event appears for that release with symbolicated frames.

## Recovery

- **Release shows no dSYMs.** Check that `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, and `SENTRY_PROJECT` are set, then run the manual upload above against the archive of that version, or re-run the release.
- **No events at all from a release build.** Check that the CI log has no `SENTRY_DSN_REST secret is empty` warning, and that the user did not turn off **Send crash reports**. A build without a DSN cannot be fixed later; ship the next version with the secret set.
- **Frequent system-hang noise.** Add the signature to `systemNoiseSignatures` in `SystemHangFilter` and ship a release.
