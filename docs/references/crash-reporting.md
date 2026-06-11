# Crash reporting

Codans uses Sentry to capture uncaught crashes (Mach exceptions, POSIX
signals, `NSException`) and Swift errors on release builds, with the
stack trace symbolicated against the dSYMs produced by the same archive.
The SDK never runs in DEBUG builds and can be turned off per-install.

See [ExecPlan 0017](../exec-plans/0017-crash-reporting.md) for the
design rationale and the alternatives that were considered.

## Privacy stance

- DEBUG builds never report.
- Release builds default to opt-in (`general.crashReportsEnabled = true`).
  Users can disable in **Settings → General → Send crash reports**;
  disabling also clears the per-install random identifier so a future
  re-enable cannot be joined to past sessions.
- `sendDefaultPii = false` — Sentry's auto-collected IP and device-name
  fields are off.
- The per-install identifier is a random UUID stored in `UserDefaults`
  under `com.gumpw.codans.install-id`. It is not derived from device
  hardware, account, or filesystem state.
- `SystemHangFilter` drops events whose every stack frame is in a known
  macOS / AppKit noise list (`mach_msg`, `__CFRunLoopRun`, Mission
  Control / WindowServer round-trips). New false positives are added
  to `systemNoiseSignatures` and re-shipped.

## How a release report flows

```
release.sh release
 │
 ├── archive               xcodebuild archive (.xcarchive + dSYMs)
 ├── upload-symbols        sentry-cli registers codans@<version> + uploads dSYMs
 ├── notarize app          Apple notary + staple
 ├── dmg                   sign DMG
 └── notarize DMG          Apple notary + staple
```

`upload-symbols` is idempotent — `releases new` is a no-op on an existing
release, `debug-files upload` deduplicates by debug-id, and `releases
finalize` is safe to repeat. The step also runs as a stand-alone
subcommand:

```bash
SENTRY_AUTH_TOKEN=... apps/mac/scripts/release.sh upload-symbols
```

Without `SENTRY_AUTH_TOKEN` the step is a friendly no-op and the rest
of the pipeline still produces a notarized DMG.

### In CI

`.github/workflows/release.yml` (tag-triggered) and
`release-tip.yml` (every push to `main`) both run the same archive →
notarize → dmg pipeline. They wrap two Sentry-specific steps around the
Archive call:

1. **Inject Sentry DSN** — writes `apps/mac/Configurations/Secrets.xcconfig`
   from the `SENTRY_DSN_REST` repository secret *before* Archive so the
   built `Info.plist` carries a real DSN rather than the bare `https://`
   fallback. An empty/missing secret only emits a warning; the workflow
   still produces a usable DMG, but it will not phone home.
2. **Upload dSYMs** — runs `release.sh upload-symbols` *after* Archive
   and *before* notarize, using the `SENTRY_AUTH_TOKEN` secret. Same
   tolerance: missing token degrades to a no-op.

Add both secrets via `gh secret set` (or the GitHub UI):

```bash
gh secret set SENTRY_DSN_REST \
  --body '7a35f7894920ef885837030b57b18702@o4511454478467072.ingest.us.sentry.io/4511455005310976'
gh secret set SENTRY_AUTH_TOKEN --body 'sntryu_xxxxxxxx'
```

(Both values here are illustrative — substitute your real values. The
DSN host+path is not technically secret, but routing it through Actions
secrets keeps it out of workflow logs and makes future rotation a
single-place edit.)

## Setup checklist (first time)

1. **Create the Sentry project.** The default organisation and project
   slugs become part of the dashboard URL. Capture the DSN —
   it is not secret per se, but treat it as one.

2. **Generate an auth token** with scopes `project:read`,
   `project:write`, `project:releases`. Store it in
   `~/.sentryclirc` and as `SENTRY_AUTH_TOKEN` in CI secrets:

   ```ini
   # ~/.sentryclirc
   [auth]
   token=sntryu_xxxxxxxx

   [defaults]
   org=<org-slug>
   project=<project-slug>
   url=https://sentry.io/
   ```

3. **Add the DSN to the build.** Copy the template, fill in the host +
   path portion (everything after `https://`), and confirm the file
   stays gitignored:

   ```bash
   cp apps/mac/Configurations/Secrets.xcconfig.template \
      apps/mac/Configurations/Secrets.xcconfig
   $EDITOR apps/mac/Configurations/Secrets.xcconfig    # set SENTRY_DSN_REST
   git status -- apps/mac/Configurations/Secrets.xcconfig  # should be ignored
   ```

   Note: `mac-Info.plist` carries the literal `https://` prefix because
   xcconfig strips `//` as a comment delimiter — only the host + path
   portion of the DSN travels through `SENTRY_DSN_REST`.

4. **Cut a release.** `release.sh release` performs `upload-symbols`
   between archive and notarize; verify the dashboard shows the
   release `codans@<MARKETING_VERSION>` with the dSYMs attached.

5. **Smoke test from a release build** by invoking `SentrySDK.crash()`
   from a DEBUG-only menu item or `lldb`. The first event for that
   release should appear in the dashboard with symbolicated frames.

## Disabling crash reporting

- **As a user:** Settings → General → Send crash reports (off).
  Takes effect on next launch (the SDK is bootstrapped once in
  `CodansApp.init()`).
- **As a contributor without a DSN:** the bootstrap detects an
  empty `SentryDSN` Info.plist value and short-circuits. No additional
  configuration is needed; your release-mode build simply does not
  upload anything.

## Where things live

| Concern | Path |
|---|---|
| Bootstrap | `apps/mac/codans/App/Telemetry/CrashReporting.swift` |
| Install id | `apps/mac/codans/App/Telemetry/InstallIdentifier.swift` |
| Noise filter | `apps/mac/codans/App/Telemetry/SystemHangFilter.swift` |
| Settings toggle | `general.crashReportsEnabled` in `Settings/GeneralSettings.swift` |
| DSN plumbing | `Configurations/Secrets.xcconfig` → `mac-Info.plist` `SentryDSN` |
| Release symbol upload | `apps/mac/scripts/release.sh` `upload-symbols` |
| SDK pin | `apps/mac/Tuist/Package.swift` (`getsentry/sentry-cocoa`) |
