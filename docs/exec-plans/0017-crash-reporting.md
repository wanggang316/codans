# ExecPlan: Crash reporting via Sentry

**Status:** In Progress
**Author:** Gump
**Date:** 2026-05-25

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

End users hit crashes that we never see, because Codans ships through a notarized Developer ID DMG (and Homebrew tap) rather than the App Store — so Apple's Xcode Organizer crash pipeline is not available to us. After this change, any uncaught Mach exception, POSIX signal, `NSException`, or Swift error in a release build is uploaded to a hosted dashboard with symbolicated stack traces, allowing us to triage real-world failures without the user having to reproduce or report them.

Users keep control: a `crashReportsEnabled` toggle in **Settings → General** turns the SDK off entirely, and **DEBUG builds never report**. Release names are pinned to `codans@<MARKETING_VERSION>` so a regression can be localised to a specific build.

## Progress

- [x] Decision: choose Sentry over alternatives (see Decision Log)
- [x] Step 1 — Add `sentry-cocoa` (`from: 9.14.0`) to Tuist Package, force dynamic framework
- [x] Step 2 — Plumb `SENTRY_DSN` through `Secrets.xcconfig` (gitignored) → `mac-Info.plist` placeholder
- [x] Step 3 — Add `Telemetry/CrashReporting.swift` bootstrap with `Configuration` parser + `isEnabled` gate
- [x] Step 4 — Add `Telemetry/SystemHangFilter.swift` `beforeSend` scrubber
- [x] Step 5 — Add `Telemetry/InstallIdentifier.swift` (UUID in `UserDefaults`, cleared on opt-out)
- [x] Step 6 — Extend `GeneralSettings` with `crashReportsEnabled: Bool` (default `true`)
- [x] Step 7 — Surface the toggle in `SettingsGeneralView` with a privacy explainer
- [x] Step 8 — Call `CrashReporting.bootstrap` from `CodansApp.init`
- [x] Step 9 — Add `sentry-cli` to `mise.toml`; `apps/mac/scripts/release.sh upload-symbols` registers release + uploads dSYMs
- [x] Step 10 — Unit tests: `Configuration.init` parser + `CrashReporting.isEnabled` gate + `SystemHangFilter` matching + `InstallIdentifier` round-trip
- [x] Step 11 — Write `docs/references/crash-reporting.md`
- [x] Step 12 — App-target build green; lint clean on every new file; new unit tests compile (the broader test target has pre-existing compile failures — see Discoveries)

## Surprises & Discoveries

### DSC-1 — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` cascades into telemetry types

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
unannotated `enum` declared inside the `codans` app target inherits
main-actor isolation. Two consequences:

- `InstallIdentifier.current` had to be made `nonisolated` so the unit
  tests (which run with `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`)
  can call it from a synchronous context.
- `SystemHangFilter.filter` is `@Sendable` because Sentry invokes
  `beforeSend` off the main actor. A `@Sendable` synchronous method
  must be nonisolated, so the whole enum is marked `nonisolated`.

### DSC-2 — Pre-existing test-target compile errors blocked end-to-end test runs

`codans/Tests/HierarchySidebarFeatureTests.swift` lines 89 and 124
fail Swift 6 strict-concurrency capture rules (`var settings` captured
in a `@Sendable` closure). Confirmed pre-existing — `git stash -u` to
baseline and re-running `xcodebuild build-for-testing` reproduces the
same errors. Out of scope for this plan; the new telemetry tests
themselves compile cleanly and `CodansCore`-side settings tests
all pass.

### DSC-3 — `make check` is whole-project; isolated lint command needed

Running `make mac-check` ran `swift-format` in place over the *entire*
project, surfacing reformat diffs for files outside this change set.
Mitigation: revert those reformats explicitly before staging and run
`swift-format` + `swiftlint` only against the new files. Pre-existing
lint violations in unrelated files (`CodansApp.bringUp`,
`GhosttyActionDecoder`, etc.) also remain — not in scope.

### DSC-6 — Original commits missed the CI release pipeline

`.github/workflows/release.yml` and `release-tip.yml` already drive the
Developer ID release; the initial implementation only wired `release.sh
upload-symbols` into the `cmd_release` chain used by manual local
releases. The workflows call `release.sh` subcommands individually
(`archive`, `notarize`, `dmg`, `notarize`) rather than the top-level
`release` subcommand, so the new upload step never ran in CI — and the
CI builds also lacked any `Secrets.xcconfig` injection, so every
tag-triggered DMG would have shipped with a bare `https://` DSN that
the bootstrap rejects as missing.

Fix: explicit `Inject Sentry DSN` step (between keychain import and
Archive) and `Upload dSYMs to Sentry` step (between Archive and
Notarize) added to both workflows. Both gracefully no-op when their
secret is absent so a release can be cut before Sentry is provisioned.

Required new secrets: `SENTRY_DSN_REST`, `SENTRY_AUTH_TOKEN`.

### DSC-5 — xcconfig truncates `//`, DSN scheme moved into mac-Info.plist

Discovered while smoke-testing the real DSN: xcconfig treats `//` as a
comment delimiter, so `SENTRY_DSN = https://abc@host/0` is parsed as
`SENTRY_DSN = https:` and the rest of the URL is silently dropped. The
canonical `$()` empty-expansion workaround did not survive the parser
on Xcode 26 either.

Fix: split the DSN. The literal `https://` scheme prefix lives in
`mac-Info.plist` as part of the plist value (where xcconfig comment
rules don't apply), and `SENTRY_DSN_REST` carries only the host + path
portion — which has no `//`. The Swift bootstrap rejects the bare
`https://` value (empty rest) as missing-DSN so the no-DSN branch
still no-ops cleanly.

Verified: `plutil -p Codans.app/Contents/Info.plist | grep -i sentry`
shows the full reassembled URL on a fresh build.

### DSC-4 — Bumped pin from 8.x to 9.14.0 after initial commit

First commit pinned `from: 8.40.0`, which resolved to 8.58.2 — but
`getsentry/sentry-cocoa` 9.x has been GA for months and 9.14.0 is the
current latest. Reviewing the 9.0 breaking-change list against our
surface:

- `enableAppHangTracking` was removed on iOS/tvOS but **macOS still
  uses V1**, so the property is still settable in our `options.start`
  block. No change needed.
- `SentryFrame.function` default changed from `<redacted>` to `nil` —
  `SystemHangFilter.filter` already gates on `if let function = …`,
  so the new behaviour is correctly handled.
- Removed APIs (V1 profiling, UserFeedback, SessionReplay options,
  `enableTracing`) — none used here.
- Minimum macOS 10.14 / Xcode 16+ — our deployment target is 14.0 and
  the build runs on Xcode 26.

Bumped pin to `from: "9.14.0"` and rebuilt; no source changes required.

## Decision Log

### DEC-1 — SDK choice: Sentry

Three credible options were considered:

| Option | Verdict |
|---|---|
| **Sentry** (`getsentry/sentry-cocoa`) | Chosen. First-class macOS support, Mach + signal + `NSException` + Swift error capture, native SwiftPM, open source server (we can self-host later without SDK churn), symbolication accepts standard dSYMs. |
| **Firebase Crashlytics** | Rejected. macOS support exists but is iOS-first; pulls in `GoogleUtilities` + Firebase Core; dSYM upload tooling assumes Xcode build phases that don't fit our `tuist generate` + `xcodebuild` release pipeline cleanly. |
| **Apple MetricKit / Xcode Organizer** | Rejected. Only reports from App Store / TestFlight installs. We ship Developer ID + DMG + Homebrew tap. |
| **Bugsnag** | Rejected. Smaller community, no compelling capability advantage. |
| **PLCrashReporter / KSCrash bare** | Rejected. Capture only — would need to build and host the backend ourselves, plus a symbolication service. |
| **App Center** | Rejected. Microsoft retired the service on 2025-03-31. |

### DEC-2 — Release telemetry only, no product analytics in this plan

This plan ships **only** crash + error capture. Product analytics (events, funnels, memory thresholds) is a separate concern with its own privacy posture and is out of scope.

### DEC-3 — Sample rates

- `tracesSampleRate = 0.05` — 5% performance trace sampling so the integration is ready if we want to look at startup or pane-creation latency later, but stays well below any plausible free-tier ceiling.
- `enableAppHangTracking = false` for v1. App-hang detection on macOS has historically reported a lot of system-induced false positives (wake-from-sleep, display reconnect, Mission Control) and has had Swift-concurrency-callback edge cases that crashed apps. We turn it on in a follow-up after the baseline is quiet.
- `sendDefaultPii = false`. No IP, no device names.

### DEC-4 — Per-install identifier, not per-user identifier

A random UUID generated on first launch, persisted in `UserDefaults` under key `com.gumpw.codans.install-id`, cleared when the user toggles crash reporting off. Same ID is set on `SentrySDK.setUser` and would later be reused for any second telemetry channel so cross-system correlation works.

### DEC-5 — Where the bootstrap module lives

`apps/mac/codans/App/Telemetry/`, alongside (not inside) the existing `Features/` tree. Telemetry is a cross-cutting concern, not a user-facing feature; placing it under `App/Telemetry/` mirrors the existing `App/Theme/`, `App/Commands/` siblings and keeps it out of the TCA reducer tree.

### DEC-6 — Secrets via gitignored xcconfig, not env vars at runtime

`Configurations/Secrets.xcconfig` is gitignored. CI / local builds copy from `Secrets.xcconfig.template` and fill in the DSN. The xcconfig substitutes `$(SENTRY_DSN)` into `mac-Info.plist` at build time. At runtime, the app reads `Bundle.main.infoDictionary["SentryDSN"]`. Absent / empty → bootstrap is skipped (so contributors without the secret still ship working binaries; their builds simply don't report).

## Outcomes & Retrospective

(To be filled at milestone completion)

## Context and Orientation

Codans is a notarized Mac app distributed via Developer ID DMG (`apps/mac/scripts/release.sh`) and a Homebrew tap. Sparkle (`SUFeedURL` in `mac-Info.plist`) handles auto-updates against `releases/latest/download/appcast.xml`. There is currently no end-user crash visibility.

Key source files:

- `apps/mac/codans/App/CodansApp.swift` — `@main`. New bootstrap call inside `init()`, after the existing `prepareDependencies` block.
- `apps/mac/Tuist/Package.swift` — Tuist external dependencies; `packageSettings.productTypes` already pins `Sparkle` as `.framework`. Add `Sentry` the same way.
- `apps/mac/Project.swift` — `codans` target's `dependencies` array.
- `apps/mac/Configurations/Project.xcconfig` — base xcconfig referenced by both Debug and Release. Include a new `Secrets.xcconfig` line that user/CI provides.
- `apps/mac/Configurations/mac-Info.plist` — add `<key>SentryDSN</key><string>$(SENTRY_DSN)</string>`.
- `apps/mac/CodansCore/Settings/GeneralSettings.swift` — extend with `crashReportsEnabled: Bool` (default `true`), Codable with `decodeIfPresent ?? true` to tolerate older settings files.
- `apps/mac/codans/App/Features/Settings/Panes/SettingsGeneralView.swift` — add the toggle row + explainer.
- `apps/mac/scripts/release.sh` — append `cmd_upload_symbols` step after notarization (registers release + uploads dSYMs).

Definitions:

- **DSN** — Sentry's "data source name", a URL embedding project + public key. Identifies which project events land in. Not a credential — it can ship in the binary.
- **dSYM** — Apple's debug symbol bundle. Required for stack-trace symbolication. Generated by `xcodebuild archive` next to the `.xcarchive`.
- **App Hang** — main thread blocked > N seconds. We disable this in v1 (see DEC-3).

## Plan of Work

### Milestone 1 — SDK wired, opt-out toggle live, DEBUG no-op

At the end of M1 a release build started by a user with the DSN baked in initializes Sentry on launch; a DEBUG build does not. The General settings pane has a Crash Reports toggle that turns the SDK off on next launch; flipping it off also clears the install id from `UserDefaults`. No event has been verified end-to-end yet — that is M2.

Edits, in order:

1. **`apps/mac/Tuist/Package.swift`**: add `.package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.40.0")`; in `packageSettings.productTypes` add `"Sentry": .framework`. Run `make mac-generate` and confirm the resolved `Package.resolved` pins a version.

2. **`apps/mac/Project.swift`** (`codans` target): append `.external(name: "Sentry")` to `dependencies`.

3. **`apps/mac/Configurations/Project.xcconfig`**: append `#include? "Secrets.xcconfig"` (the `?` form: missing-file tolerant). Create `Configurations/Secrets.xcconfig.template` with `SENTRY_DSN = ` blank. Add `Configurations/Secrets.xcconfig` to `.gitignore`.

4. **`apps/mac/Configurations/mac-Info.plist`**: add `SentryDSN = $(SENTRY_DSN)` entry.

5. **`apps/mac/CodansCore/Settings/GeneralSettings.swift`**: add `public var crashReportsEnabled: Bool` (default `true`). Add to `CodingKeys`, the memberwise init, the custom `init(from:)` (with `decodeIfPresent ?? true`).

6. **`apps/mac/codans/App/Features/Settings/SettingsStore.swift`**: extend the existing `mutateGeneral` API (or equivalent) so views can flip the new field through the debounced writer.

7. **`apps/mac/codans/App/Telemetry/CrashReporting.swift`** (new): contains the `Configuration` parser (reads `SentryDSN` from Info.plist), the `isEnabled(settings:isDebugBuild:)` gate, and a `bootstrap(settings:infoDictionary:)` static that calls `SentrySDK.start { … }` with the v1 config (see DEC-3) and `SentrySDK.setUser(.init(userId: InstallIdentifier.current))`. Whole body is `#if !DEBUG`-gated.

8. **`apps/mac/codans/App/Telemetry/InstallIdentifier.swift`** (new): `static var current: String { get }` reads/persists a UUID under `UserDefaults.standard`; `static func reset()` clears it.

9. **`apps/mac/codans/App/Telemetry/SystemHangFilter.swift`** (new): pure function `filter(_ event: Event) -> Event?`. Walks the event's stack frames; if every non-system frame is in a known noise list (`mach_msg`, `NSMenuBarDisplayManagerActiveSpaceChanged`, `CGSConnectionByID` etc.) returns `nil` to drop the event. Wired as `options.beforeSend`.

10. **`apps/mac/codans/App/CodansApp.swift`** `init()`: after `prepareDependencies`, call `CrashReporting.bootstrap(settings: initialSettings, infoDictionary: Bundle.main.infoDictionary ?? [:])`. (Needs access to the same `Settings` that `SettingsStore` later reads — re-use the load helper or read the file once here.)

11. **`apps/mac/codans/App/Features/Settings/Panes/SettingsGeneralView.swift`**: add a `Toggle("Send crash reports")` row plus a `Text("Helps fix crashes you experience…")` caption with a privacy stance. When the toggle goes from `on → off`, also invoke `InstallIdentifier.reset()`.

12. **Tests** (`apps/mac/codans/Tests/`): `CrashReportingTests` for the `Configuration` parser (whitespace, empty, missing) and `isEnabled` gate (toggle off, DEBUG flag, no DSN); `SystemHangFilterTests` for the matching logic; `InstallIdentifierTests` for round-trip + reset.

### Milestone 2 — Release pipeline uploads dSYMs and registers release

At the end of M2, every notarized DMG produced by `release.sh release` has its dSYMs uploaded to Sentry and its release registered with the matching `codans@<MARKETING_VERSION>` name. A test crash from a release build resolves to readable Swift source lines in the dashboard.

1. **`mise.toml`**: add `"getsentry/tools/sentry-cli" = "latest"` under `[tools]`. Run `mise install` and verify `sentry-cli --version`.

2. **`apps/mac/scripts/release.sh`**: new `cmd_upload_symbols` step. After `cmd_archive` writes the `.xcarchive`, locate the dSYM bundle (`<archive>/dSYMs/*.dSYM`), then:
   - `sentry-cli releases new "codans@${version}"`
   - `sentry-cli releases set-commits --auto "codans@${version}"`
   - `sentry-cli debug-files upload --include-sources <archive>/dSYMs`
   - `sentry-cli releases finalize "codans@${version}"`
   Wire into `cmd_release` between notarize-app and dmg-build so a failure here does not bury the notarized DMG.
   Requires env var `SENTRY_AUTH_TOKEN` with scopes `project:read`, `project:write`, `project:releases`. Print a friendly message and skip (do not fail) when the token is absent — so a hot-fix release on a contributor laptop without the token still produces a notarized DMG.

3. **`docs/references/crash-reporting.md`** (new): privacy stance, where the dashboard lives (placeholder URL — user fills the org/project slug after creating the project), the dSYM upload flow, how a user turns reporting off, the system-hang filter rationale, the auth token scopes.

## Concrete Steps

From repo root:

```bash
# M1: SDK wired
$EDITOR apps/mac/Tuist/Package.swift            # add sentry-cocoa, force .framework
$EDITOR apps/mac/Project.swift                  # add .external(name: "Sentry") to codans deps
make mac-generate                               # tuist resolves the package, regenerates .xcodeproj
$EDITOR apps/mac/Configurations/Project.xcconfig
$EDITOR apps/mac/Configurations/Secrets.xcconfig.template
$EDITOR apps/mac/Configurations/mac-Info.plist
$EDITOR .gitignore                              # add Secrets.xcconfig

# settings + telemetry module
$EDITOR apps/mac/CodansCore/Settings/GeneralSettings.swift
$EDITOR apps/mac/codans/App/Telemetry/CrashReporting.swift  # new file
$EDITOR apps/mac/codans/App/Telemetry/InstallIdentifier.swift  # new file
$EDITOR apps/mac/codans/App/Telemetry/SystemHangFilter.swift  # new file
$EDITOR apps/mac/codans/App/CodansApp.swift  # bootstrap call
$EDITOR apps/mac/codans/App/Features/Settings/Panes/SettingsGeneralView.swift

# tests
$EDITOR apps/mac/codans/Tests/Telemetry/CrashReportingTests.swift
$EDITOR apps/mac/codans/Tests/Telemetry/SystemHangFilterTests.swift
$EDITOR apps/mac/codans/Tests/Telemetry/InstallIdentifierTests.swift

# verify
make mac-check                                  # swift-format + swiftlint
make mac-build                                  # full build incl. codans
xcodebuild test -workspace apps/mac/codans.xcworkspace -scheme codans -destination 'platform=macOS' | xcsift

# M2: release pipeline
$EDITOR mise.toml                               # add sentry-cli
mise install
$EDITOR apps/mac/scripts/release.sh             # cmd_upload_symbols
$EDITOR docs/references/crash-reporting.md
```

## Validation and Acceptance

**M1 acceptance:**

1. `make mac-build` succeeds.
2. `make mac-check` reports clean.
3. `xcodebuild test ... -scheme codans` shows the three new test classes passing.
4. Launching the Debug build: in Console, no `[Sentry]` log lines appear (DEBUG no-op).
5. Launching the Release build with `Secrets.xcconfig` filled in: Console shows `[Sentry] [INFO] Initialized Sentry SDK` at startup; with the toggle flipped off it does not, and `UserDefaults` no longer contains `com.gumpw.codans.install-id`.
6. With Crash Reports toggle off and the app relaunched, a `SentrySDK.crash()` call from a DEBUG-only menu item under `Debug → Trigger Test Crash` (or `Debug → Send Test Event`) is a no-op rather than reporting to the dashboard.

**M2 acceptance:**

1. `SENTRY_AUTH_TOKEN=... apps/mac/scripts/release.sh release` produces a notarized DMG **and** logs `sentry-cli releases new ...` / `... debug-files upload ... OK` between archive and DMG steps.
2. After uploading, the dashboard shows the release `codans@<MARKETING_VERSION>` with the dSYMs attached.
3. Unsetting `SENTRY_AUTH_TOKEN` and re-running `release.sh release` still produces the notarized DMG, with a clear skip message for the upload-symbols step (no failure).

## Idempotence and Recovery

- All steps are local edits with no external side effects until M2.
- `release.sh upload-symbols` is idempotent at the Sentry side: `releases new` is a no-op for an existing release; `debug-files upload` deduplicates by UUID; `releases finalize` is idempotent.
- If `Secrets.xcconfig` is accidentally committed: rotate the DSN at the Sentry side (DSN is not strictly a secret but treat as one), `git rm --cached`, force the next release to use a fresh DSN.
- Rolling back the whole change: remove the package from `Tuist/Package.swift`, remove `.external(name: "Sentry")`, delete `App/Telemetry/`, drop the new field from `GeneralSettings`. Older settings files keep working because we used `decodeIfPresent`.

## Artifacts and Notes

Bootstrap signature (target shape):

```swift
@MainActor
enum CrashReporting {
  struct Configuration: Equatable {
    let dsn: String

    init?(infoDictionary: [String: Any]) {
      guard let trimmed = (infoDictionary["SentryDSN"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !trimmed.isEmpty
      else { return nil }
      self.dsn = trimmed
    }
  }

  static func isEnabled(settings: Settings, isDebugBuild: Bool) -> Bool {
    settings.general.crashReportsEnabled && !isDebugBuild
  }

  static func bootstrap(settings: Settings, infoDictionary: [String: Any]) {
    #if DEBUG
      return
    #else
      guard isEnabled(settings: settings, isDebugBuild: false) else { return }
      guard let configuration = Configuration(infoDictionary: infoDictionary) else { return }
      let version = (infoDictionary["CFBundleShortVersionString"] as? String) ?? "unknown"
      SentrySDK.start { options in
        options.dsn = configuration.dsn
        options.releaseName = "codans@\(version)"
        options.environment = "production"
        options.tracesSampleRate = 0.05
        options.enableAppHangTracking = false
        options.sendDefaultPii = false
        options.beforeSend = SystemHangFilter.filter
      }
      SentrySDK.setUser(.init(userId: InstallIdentifier.current))
    #endif
  }
}
```

## Interfaces and Dependencies

- **Tuist SPM**: `getsentry/sentry-cocoa`, latest 8.x. Force-typed to `.framework` so the embedded dynamic framework loads at runtime (matches how Sparkle is configured today).
- **mise**: `getsentry/tools/sentry-cli` (latest). Used only by `release.sh`.
- **Env vars**: `SENTRY_AUTH_TOKEN` (release pipeline only). Scopes: `project:read`, `project:write`, `project:releases`.

Public surface added:

- `CrashReporting.Configuration`
- `CrashReporting.isEnabled(settings:isDebugBuild:) -> Bool`
- `CrashReporting.bootstrap(settings:infoDictionary:)`
- `InstallIdentifier.current: String`
- `InstallIdentifier.reset()`
- `SystemHangFilter.filter(_ event: Event) -> Event?`
- `GeneralSettings.crashReportsEnabled: Bool`
