# ExecPlan: Mac app packaging, signing, and release pipeline

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-04-28

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

Today the repository can only produce a Debug build that runs on the developer's own Mac. There is no archive flow, no Developer ID signing, no notarization, no DMG, no published release. After this plan, a maintainer can:

1. Run `make mac-release VERSION=0.2.0` on their Mac and get a notarized, stapled `Codans.dmg` plus a checksums file in `apps/mac/.build/release/`.
2. Push a `v0.2.0` git tag and have GitHub Actions produce the same artifacts in CI and attach them to a draft GitHub Release.
3. Hand a user the resulting DMG and have it open on a stock macOS 14+ machine without Gatekeeper warnings.

The pipeline must also embed the `codans` CLI inside the app bundle so [c4-cli.md §Surface](../design-docs/c4-cli.md) — which already specifies `codans` ships inside `<app>/Contents/Resources/` and is installed to `~/.local/bin/codans` on first launch — has a binary to point at.

## Progress

- [x] M1 — Identity, productName, entitlements, embedded `codans` — 2026-04-28
- [x] M2 — Local archive + Developer ID signing script — 2026-04-28 (script + preflight verified; end-to-end archive needs Developer ID identity in keychain)
- [x] M3 — Notarization + stapling — 2026-04-28 (script written; live notarytool round-trip needs App Store Connect API key)
- [x] M4 — DMG packaging (signed + notarized) — 2026-04-28 (script written; full chain needs M2/M3 credentials present)
- [x] M5 — Single-source version bump + Makefile front door — 2026-04-28
- [x] M6 — GitHub Actions release workflow on tag — 2026-05-05 (run #25369709068 produced draft release v0.1.0 with Codans-0.1.0.dmg + .sha256 attached; ~21 min cold)
- [ ] M7 — (Deferred) Sparkle auto-update — captured as ADR only, no code

## Surprises & Discoveries

- **2026-04-28 (M1, superseded by DEC-11): Tuist warned on spaces in `productName` but the build worked.** `mise exec -- tuist generate` printed `Invalid product name 'Codans'. This string must contain only alphanumeric (A-Z,a-z,0-9), period (.), hyphen (-), and underscore (_) characters.` and proceeded anyway. xcodebuild resolved `PRODUCT_NAME=Codans`, `WRAPPER_NAME=Codans.app`, `EXECUTABLE_NAME=Codans` correctly; `Codans.app` built, signed ad-hoc, and launched. Originally accepted the warning. Reverted to `productName: "Codans"` later the same day per DEC-11 — the Tuist warning is the canary, and downstream packaging tools that have to quote the path are the actual risk.
- **2026-04-28 (M1): `xcodebuild` first run after pbxproj regeneration printed `** BUILD FAILED ** (3 failures)` but a second invocation a moment later (piped through xcbeautify) succeeded.** No source change between the two runs. Likely a transient stale-derived-data effect from Tuist regenerating the pbxproj while a previous build's incremental graph was still indexed. Re-running was sufficient; not adding a `xcodebuild clean` step in the Makefile because the cost (full rebuild on every generate) outweighs the rare flake.
- **2026-04-28 (review): five real bugs that `bash -n` cannot catch.** The `agent-skills:code-reviewer` pass on the M1–M5 commits found:
  1. `release.sh` piped xcodebuild output through `"$(mise_xcbeautify_cmd)" --is-ci` — the `$()` returned the multi-word string `mise exec -- xcbeautify`, which bash quoted into a single argv that no binary on disk matches. Every credentialed archive would have failed at the pipe. Fixed by replacing the helper with a `beautify` function called directly. Lesson: any helper that returns a command string must be called as `eval`, or it must be a function called by name — never `"$(helper)"` followed by extra args.
  2. `notarize.sh` `cleanup()` iterated `"${cleanup_files[@]}"` unguarded — bash 3.2 (default `/bin/bash` on macOS) errors on empty-array expansion under `set -u`. Would fire on every `.dmg` notarization (the `.app` branch happens to populate the array first). Fixed with `[ "${#arr[@]}" -gt 0 ]` guards on both arrays.
  3. `notarize.sh` decoded the App Store Connect P8 with `base64 --decode` — BSD `base64` (which macOS ships) rejects trailing whitespace, and CI dashboards routinely append CR/LF to pasted secrets. Fixed with `tr -d ' \n\r\t' | base64 -D`.
  4. `notarize.sh` only added the inner zip path to cleanup, leaking the `mktemp -d` parent dir. Fixed by tracking dirs separately in `cleanup_dirs` and `rm -rf`-ing them.
  5. `make-dmg.sh` signed the DMG without first verifying the inner `.app` signature. A stale unsigned helper would sail through to notarytool and only fail 30 minutes later. Fixed by running `codesign --verify --deep --strict` on the .app *before* `hdiutil create`.
  Also fixed: `mac-bump-version` git-diff guard now uses `HEAD --` so staged changes also block the bump; `release.sh` `print_usage` is now a heredoc instead of a fragile `sed -n` line range; `cmd_archive` sets the EXIT trap before the `mktemp` call to close a SIGINT-leak window on the team-ID-bearing ExportOptions plist.

## Decision Log

- **DEC-1: DMG, not zip, as the primary artifact.** A signed+notarized DMG is the convention macOS users expect from a Developer ID app, and the `/Applications` drop-target inside the DMG removes the most common "users run the app from Downloads" support issue. Cost is one extra `hdiutil` step over a flat zip.
- **DEC-2: Embed `codans` inside `Codans.app/Contents/Resources/bin/codans`, not `Contents/MacOS/`.** Apple convention reserves `Contents/MacOS/` for binaries Launch Services can run; helper CLIs commonly live in `Resources/`. The first-launch installer in [c4-cli.md §D3](../design-docs/c4-cli.md) symlinks to `~/.local/bin/codans`, so the canonical inside-bundle path is what the symlink target needs to be stable. Putting it under `Resources/bin/` keeps it grouped with `Resources/git-wt/wt`.
- **DEC-3 (revised by DEC-11): Set `productName: "Codans"` so the bundle filename has no space.** Originally proposed as `"Codans"` to match the user-facing brand 1:1; reverted before first release per DEC-11 — too many downstream tools (codesign, notarytool, hdiutil, gh release upload) misbehave on spaced paths in subtle ways. User-facing identity stays "Codans" via `CFBundleDisplayName` + `CFBundleName`, which is what Finder, Dock, and the menu bar read. Only the on-disk `Codans.app` filename and the `Contents/MacOS/Codans` executable name change.
- **DEC-4: One Release.xcconfig holding `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY`, gitignored.** The Tuist-generated pbxproj must not bake a team ID into version-controlled files because (a) a different contributor with a different Apple ID could not regenerate, and (b) the team ID is mildly sensitive. Local devs override locally; CI provides the values via env vars consumed by the release script.
- **DEC-5: Notarize via App Store Connect API key (not app-specific password).** API keys are revocable, scoped, and the only credential type that works cleanly in headless CI without 2FA prompts. The local maintainer flow uses `xcrun notarytool store-credentials` to cache the same key in the login keychain, so `release.sh` reads from `--keychain-profile codans-notary` locally and from env vars (`AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8`) in CI.
- **DEC-6: Sparkle deferred to a separate plan.** Sparkle adds an appcast, a public EdDSA key in Info.plist, hosted XML, and a UI surface for "Check for updates." None of that is needed to produce a v0.x DMG that users can download manually. Recording this as DEC-6 so the omission is explicit, not accidental.
- **DEC-7: GitHub Actions release workflow deferred.** There is no GitHub-hosted release channel for codans in v1 (confirmed with Gump on 2026-04-28). The local `make mac-release` flow (M1–M5) covers the maintainer's actual distribution path. A workflow file is value-add only when a distribution repo exists; writing it now risks bit-rot before first use. M6 stays in the plan as a stub so the future maintainer doesn't have to re-derive the secret list and the keychain-import dance.
- **DEC-8 (M1): codans CLI signed for Release via `CODE_SIGNING_ALLOWED[config=Debug]=NO`, not by removing the override.** Tuist accepts the `[config=Debug]` modifier directly in the settings dict and passes it through to xcconfig syntax. Removing the line entirely would force-sign codans in Debug too — contributors without a Developer ID would then fail to build the CLI for local development.
- **DEC-9 (M2): ExportOptions.plist uses `__DEVELOPMENT_TEAM__` placeholder substituted by `sed` at script time, not `$(DEVELOPMENT_TEAM)`.** `xcodebuild -exportArchive` does not expand environment variables inside the plist, so `$(DEVELOPMENT_TEAM)` would be passed through literally and the export would fail. Sed substitution into a tempfile (cleaned by `trap`) is the documented Apple workaround.
- **DEC-10 (M5): `mac-bump-version` always increments `CURRENT_PROJECT_VERSION` by 1, even when `MARKETING_VERSION` is repeated.** Apple requires strictly increasing build numbers per bundle-id in the App Store, and even off-store the monotonic counter is what Sparkle and the macOS update plumbing key on. Resetting the counter on a marketing-version change would silently regress that invariant.
- **DEC-12 (M2 redesign, 2026-05-05): Bypass `xcodebuild -exportArchive` entirely; copy the signed .app directly out of the .xcarchive.** First credentialed run hit `IDEDistributionMethodManager` `Unknown Distribution Error` / `expected one {} but found developer-id` — Apple's IDE distribution code path requires a logged-in Apple ID in Xcode preferences (the GUI app), which is impossible on a headless CI runner and impractical to keep current locally. exportArchive's only job for Developer ID is `cp -R`; replicating it in shell removes a hard dependency on Xcode account auth and trims ~30s off every release. ExportOptions.plist deleted. See DEC-9 (now obsolete).
- **DEC-13 (M6 reactivation, 2026-05-05): Resurrect the GitHub Actions release workflow.** DEC-7 deferred M6 because there was no GitHub release channel; the repository origin has since been pointed at `github.com:wanggang316/codans.git`. Implemented per the M6 sketch with one small addition: `DEVELOPER_ID_NAME` is its own secret (rather than embedded in `CODE_SIGN_IDENTITY`) so the spaced "WANG GANG" string doesn't have to thread through xcconfig quoting.
- **DEC-14 (signing chain fixes, 2026-05-05): Five layered fixes were needed to make Developer ID actually take effect.** Project.swift's project-level `CODE_SIGN_STYLE: "Automatic"` baked into every target's pbxproj overrode the xcconfig (target dict > project xcconfig in Xcode precedence) — scoped to `[config=Debug]`. Tuist's `defaultSettings: .essential` injects `CODE_SIGN_IDENTITY = "-"` directly into target Release configs — switched to `.essential(excluding: ["CODE_SIGN_IDENTITY"])` for both codans and codans targets. Tuist also injects an sdk-conditional variant, so the xcconfig override must use `CODE_SIGN_IDENTITY[sdk=macosx*] = …` to win. The codans target needed `ENABLE_HARDENED_RUNTIME[config=Release] = YES` because notarization rejects unsigned/non-HR nested binaries. ARCHS pinned to arm64 because libghostty's static imgui has missing x86_64 symbols and concurrent xcodebuilds had hung the x86_64 link. Recorded as one big DEC because every fix on its own would still produce ad-hoc; the bug needed all five.
- **DEC-15 (signing channel rewrite, 2026-05-05): Stop fighting xcconfig precedence; pass signing as xcodebuild command-line build settings.** xcodebuild's command-line build settings sit at the top of Xcode's resolution order, so they win regardless of what target buildSettings, xcconfig, or project defaults say. `release.sh archive` now invokes `xcodebuild archive ... CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=… CODE_SIGN_IDENTITY=<SHA-1> OTHER_CODE_SIGN_FLAGS=--timestamp ARCHS=arm64 ONLY_ACTIVE_ARCH=NO`. The identity SHA is auto-detected from `security find-identity` (or `DEVELOPER_ID_IDENTITY_SHA` env in CI). This fully obsoletes DEC-14's `defaultSettings: .essential(excluding: ...)` pair, the `Release.xcconfig` mechanism, the `Release.xcconfig.example` template, and the `#include?` indirection in `Project.xcconfig` — all of which were reverted. SHA-based identity also drops the need for a separate `DEVELOPER_ID_NAME` GitHub secret.
- **DEC-16 (CI Xcode pinning, 2026-05-05): Pin macos-26 runner to Xcode 26.0 via `DEVELOPER_DIR`, not just `xcode-select`.** macos-26's default Xcode symlink at `/Applications/Xcode.app` points at 26.2, whose macOS SDK ships a `SwiftUICore.tbd` with a bundle-id allowed-clients list that does not include our app. The linker auto-discovers SwiftUICore through one of the SPM deps and fails. Xcode 26.0.1 has the same SDK restriction, so the fix wasn't "use older Xcode" — it was "use the same Xcode locally and in CI so the build is reproducible". `apps/mac/Makefile`'s `export DEVELOPER_DIR ?= …Xcode.app…` falls back to whatever `Xcode.app` points at, which on macos-26 is 26.2 — so the workflow now writes `DEVELOPER_DIR=/Applications/Xcode_26.0.app/...` to `$GITHUB_ENV` to shadow the Makefile's default. The actual SwiftUICore link error was a downstream symptom of an x86_64 link path that DEC-15's `ARCHS=arm64` pin closed.
- **DEC-11 (post-review): Drop the space from `productName`; ship `Codans.app` instead of `Codans.app`.** Tuist warned at generate time, the M1 Debug build still produced `Codans.app`, and three lint runs were green — so the original "warning is benign at the xcodebuild layer" verdict (Surprise §1) was correct in narrow scope. But before the first credentialed release, on reflection: every script in the pipeline (`release.sh`, `make-dmg.sh`, `notarize.sh`) hardcodes the path with quoted strings, and *one* future helper that forgets to quote will silently break with no useful diagnostic. The cost of the rename is low (one Tuist setting, three scripts, two doc lines) and the cost of a broken DMG hours into a release flow is high. DMG filename also moves from `Codans <version>.dmg` to `Codans-<version>.dmg` for the same reason. Volume name (DMG mount label) stays `Codans` — that string is user-facing, not a path.

## Outcomes & Retrospective

### M1 — Identity, productName, entitlements, embedded `codans` (2026-04-28)

**What landed:** `apps/mac/Project.swift` now sets `productName: "Codans"` and `entitlements: .file(path: "Configurations/codans.entitlements")` on the app target; `codans`'s blanket `CODE_SIGNING_ALLOWED=NO` was scoped to `[config=Debug]` so Release will sign the CLI for embedding. New files: `apps/mac/Configurations/codans.entitlements` (empty `<dict/>`) and `apps/mac/scripts/embed-codans.sh` (modeled on `embed-git-wt.sh`). `docs/architecture.md` Codemap row for `codans` records the embedding.

**Verification:**
- `mise exec -- tuist generate --no-open` succeeds (with a Tuist style warning about the space in productName — see Surprises).
- `xcodebuild ... build` produces `Codans.app` at `~/Library/Developer/Xcode/DerivedData/codans-*/Build/Products/Debug/Codans.app`.
- `/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier"` returns `com.gumpw.codans`; `CFBundleDisplayName` and `CFBundleName` both `Codans`.
- `codesign -d --entitlements -` shows the (Debug-injected) `get-task-allow=true` only — the empty Release entitlements file is intact.
- `Codans.app/Contents/Resources/bin/codans --version` runs from the embedded location.

**Carry-forward to M2:** Release configuration is now structurally ready for Developer ID signing — the entitlements file exists, codans will sign in Release, and the bundle filename is final. M2 needs `Release.xcconfig` (gitignored) + `ExportOptions.plist` + `release.sh archive`.

### M2-M5 — Local release pipeline scripts (2026-04-28)

**What landed:**
- `apps/mac/Configurations/Release.xcconfig.example` — template for per-maintainer Developer ID identity. Real `Release.xcconfig` is gitignored.
- `apps/mac/Configurations/ExportOptions.plist` — Developer ID export options with a `__DEVELOPMENT_TEAM__` placeholder substituted by sed at script time (DEC-9).
- `apps/mac/Configurations/Project.xcconfig` — `#include? "Release.xcconfig"` for optional injection of signing identity into the build.
- `apps/mac/scripts/release.sh` — orchestrator with `archive` / `notarize` / `dmg` / `release` subcommands plus preflight checks for Release.xcconfig presence, DEVELOPMENT_TEAM validity, and "Developer ID Application" identity in keychain.
- `apps/mac/scripts/notarize.sh` — `xcrun notarytool submit --wait` + `stapler staple` worker. Credentials via App Store Connect API key (env vars in CI shape: `AC_API_KEY_ID`/`AC_API_ISSUER_ID`/`AC_API_KEY_P8`) or `--keychain-profile` (default `codans-notary`) seeded once with `xcrun notarytool store-credentials`.
- `apps/mac/scripts/make-dmg.sh` — pure `hdiutil`-based DMG builder, no `brew install create-dmg` dep. Stages app + `/Applications` symlink, signs DMG, writes sibling `.sha256`.
- `apps/mac/Configurations/mac-Info.plist` — `CFBundleShortVersionString=$(MARKETING_VERSION)`, `CFBundleVersion=$(CURRENT_PROJECT_VERSION)`. Single source of version truth is now `Project.xcconfig`.
- `apps/mac/Makefile` + top-level `Makefile` — new targets `mac-archive`, `mac-release`, `mac-bump-version`. `bump-version` refuses on missing `VERSION=` and on a dirty `apps/mac/Configurations/` working tree.

**Verification (what was actually exercised here):**
- `bash -n` syntax-clean on all four shell scripts.
- `apps/mac/scripts/release.sh --help` prints the documented usage.
- `apps/mac/scripts/release.sh archive` aborts with "missing Release.xcconfig" — preflight works.
- `apps/mac/scripts/release.sh notarize` aborts with "missing Codans.app" — chain dependency wiring works.
- `make mac-bump-version` — no VERSION → actionable error; dirty Configurations → refusal; clean tree + VERSION=0.1.1 → updates Project.xcconfig to MARKETING_VERSION=0.1.1, CURRENT_PROJECT_VERSION=2 as designed (then reverted to keep 0.1.0/1).
- Debug build re-verified after the Info.plist `$(MARKETING_VERSION)` substitution: `PlistBuddy` reads `0.1.0` / `1` from the embedded Info.plist.

**Not yet exercised (limited by environment):**
- `xcodebuild archive` end-to-end with a real Developer ID identity — requires the maintainer to import the cert into the keychain and create `Release.xcconfig`.
- `xcrun notarytool submit` round-trip with Apple's notary service — requires API key + network.
- `make-dmg.sh` against a real signed app — gated on the above.
- `make mac-release` end-to-end — gated on all of the above.

These can only be exercised by Gump on his own Mac; the scripts' arg shapes and preflight messages are designed so a first run surfaces credential gaps without producing partial artifacts.

## Context and Orientation

Related documents:
- Product spec: [docs/product-spec.md](../product-spec.md)
- Architecture: [docs/architecture.md](../architecture.md) — Codemap, Dependency Direction, Architectural Invariants
- CLI design (governs `codans` install model): [docs/design-docs/c4-cli.md](../design-docs/c4-cli.md) — §Surface, §D3
- Bootstrap plan (current build pipeline): [docs/exec-plans/0001-bootstrap-monorepo.md](0001-bootstrap-monorepo.md)
- Golden rules: [docs/golden-rules.md](../golden-rules.md) — especially §7 "Enforce architecture mechanically"

Key source files (all paths relative to repo root):
- `apps/mac/Project.swift` — Tuist target graph. The `codans` app target at line 188 already enables Hardened Runtime; `codans` at line 164 sets `CODE_SIGNING_ALLOWED=NO` and will need that lifted for Release config.
- `apps/mac/Configurations/Project.xcconfig` — `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`. Single source of version truth after M5.
- `apps/mac/Configurations/mac-Info.plist` — `CFBundleShortVersionString`, `CFBundleVersion`. Currently hard-coded `0.1.0`/`1`; M5 changes them to `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` so a single edit in the xcconfig propagates.
- `apps/mac/Makefile` — Top-level mac targets. `mac-archive` / `mac-release` / `mac-bump-version` get added in M2 / M5.
- `apps/mac/scripts/build-ghostty.sh` — Existing fingerprint-cached static-XCFramework build. Release pipeline reuses it unchanged; the XCFramework links statically into the app binary so it does not require its own signature.
- `apps/mac/scripts/embed-git-wt.sh` — Existing post-action that copies `wt` into `Contents/Resources/git-wt/wt`. The new `codans` embedding script (M1) follows the same shape.

New files this plan creates:
- `apps/mac/Configurations/codans.entitlements` — Hardened Runtime entitlements for the app.
- `apps/mac/Configurations/Release.xcconfig` — Local `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY` (gitignored). A `Release.xcconfig.example` is checked in.
- `apps/mac/Configurations/ExportOptions.plist` — `xcodebuild -exportArchive` options for `developer-id` method.
- `apps/mac/scripts/embed-codans.sh` — Post-action: copy `codans` into `Codans.app/Contents/Resources/bin/codans`.
- `apps/mac/scripts/release.sh` — Orchestrator: archive → export → sign → notarize → staple → DMG.
- `apps/mac/scripts/make-dmg.sh` — Pure `hdiutil`-based DMG builder, no `brew install create-dmg` dep.
- `apps/mac/scripts/notarize.sh` — Wraps `xcrun notarytool submit --wait` + `stapler`.
- `.github/workflows/release.yml` — GitHub Actions workflow, tag-triggered.

Terms:
- **Hardened Runtime.** A macOS code-signing flag that opts the binary into stricter runtime protections (no unsigned dylib loads, no unsigned executable memory, etc.) and is mandatory for notarization. Already on for the `codans` target in `Project.swift:241`.
- **Notarization.** Apple's automated malware scan of a signed binary. Returns a "ticket" that gets *stapled* to the artifact so Gatekeeper accepts it offline.
- **Stapling.** Embedding the notarization ticket into the artifact (`.app`, `.dmg`) so users on first launch don't need network access to verify.
- **Developer ID Application.** The certificate type used to distribute apps outside the Mac App Store. Distinct from "Apple Development" (used for local debug) and "Mac App Store" (MAS-only).

## Plan of Work

The work splits into seven milestones. M1–M5 are local-only — a maintainer can run the full release on their own Mac after M5. M6 lifts that into CI. M7 is intentionally deferred.

### Milestone 1: Identity, productName, entitlements, embedded `codans`

By the end of this milestone, `make mac-build` produces `apps/mac/.build/Build/Products/Debug/Codans.app` (note the renamed bundle) with `codans` already inside `Contents/Resources/bin/codans`. Hardened Runtime entitlements live in version-controlled XML.

Work:

1. In `apps/mac/Project.swift` at the `codans` app target (line 190-247), add `productName: "Codans"` so the build product is `Codans.app`. Update the `OTHER_LDFLAGS` line if needed; nothing else changes.
2. Create `apps/mac/Configurations/codans.entitlements` with the minimum Hardened Runtime entitlements: empty `<dict/>` is the starting point. If notarization in M3 reveals libghostty needs `com.apple.security.cs.allow-unsigned-executable-memory` or `com.apple.security.cs.allow-jit`, add them then with a comment recording the symptom that prompted the addition.
3. In `Project.swift` settings for the app target, add `"CODE_SIGN_ENTITLEMENTS": "Configurations/codans.entitlements"`.
4. Lift `codans`'s blanket `CODE_SIGNING_ALLOWED=NO` (`Project.swift:178`) — switch to `CODE_SIGNING_ALLOWED[config=Debug]=NO`-style scoping so Release builds sign `codans` with the same identity as the app. Concretely: drop the unconditional override and let xcconfig handle it (Release will pick up the Developer ID identity once M2 wires it in; Debug builds still produce an ad-hoc-signed `codans` because `CODE_SIGN_STYLE=Automatic` falls back to `-` when no team is set).
5. Add `apps/mac/scripts/embed-codans.sh` modeled on `embed-git-wt.sh`: assert `SRCROOT` / `TARGET_BUILD_DIR` / `UNLOCALIZED_RESOURCES_FOLDER_PATH` / `CONFIGURATION_BUILD_DIR` are set, copy `${CONFIGURATION_BUILD_DIR}/codans` to `${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin/codans`, chmod +x. Idempotent.
6. In `Project.swift`, add a `.post` script entry to the `codans` target's `scripts:` array (next to `Embed git-wt`) that runs `scripts/embed-codans.sh`, with input `$(CONFIGURATION_BUILD_DIR)/codans` and output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/codans`. `basedOnDependencyAnalysis: true` here — unlike git-wt, the input is a build product so dependency analysis works.
7. Update [docs/architecture.md](../architecture.md) Codemap to record that `codans` is now embedded inside the app bundle, not just side-by-side in DerivedData.

Acceptance: `make mac-generate && make mac-build` succeeds. `find apps/mac/.build -name "Codans.app" -prune` finds the bundle. `ls "<found-path>/Contents/Resources/bin/codans"` shows the embedded CLI. `codesign -dv "<found-path>"` shows ad-hoc signature in Debug. The app still launches.

### Milestone 2: Local archive + Developer ID signing

By the end of this milestone, a maintainer with a Developer ID Application certificate in their login keychain can run a one-command archive that produces a signed `.app` ready for notarization.

Work:

1. Create `apps/mac/Configurations/Release.xcconfig.example` containing `DEVELOPMENT_TEAM = XXXXXXXXXX` and `CODE_SIGN_IDENTITY = Developer ID Application`. Add `Release.xcconfig` to `.gitignore`.
2. In `Project.swift`, add the Release configuration mapping at the project's top-level `configurations:` array (line 19) so the release config additionally reads `Configurations/Release.xcconfig`. Tuist's `.release(name: .release, xcconfig: ...)` only takes one path, so the mechanism is: keep `Project.xcconfig` as the base for both Debug and Release, and have Release.xcconfig included via `#include? "Release.xcconfig"` inside `Project.xcconfig` (the optional include — `?` — is silently skipped when the file is absent, so Debug builds and CI checkouts without Release.xcconfig still work).
3. Create `apps/mac/Configurations/ExportOptions.plist`:

       <plist version="1.0"><dict>
         <key>method</key><string>developer-id</string>
         <key>teamID</key><string>$(DEVELOPMENT_TEAM)</string>
         <key>signingStyle</key><string>automatic</string>
         <key>destination</key><string>export</string>
       </dict></plist>

   The `$(DEVELOPMENT_TEAM)` is substituted at script time with `sed`, not by xcodebuild — `xcodebuild -exportArchive` does not expand env vars in the plist.
4. Add `apps/mac/scripts/release.sh` with a `archive` subcommand:

       ./scripts/release.sh archive

   which runs `xcodebuild archive -workspace codans.xcworkspace -scheme codans -configuration Release -archivePath .build/release/Codans.xcarchive -destination "generic/platform=macOS" SKIP_INSTALL=NO`, then `xcodebuild -exportArchive -archivePath .build/release/Codans.xcarchive -exportPath .build/release/export -exportOptionsPlist Configurations/ExportOptions.plist`.

   Pre-flight checks: assert `Release.xcconfig` exists, assert `security find-identity -v -p codesigning` lists "Developer ID Application", assert `xcrun --find xcodebuild` succeeds. Fail with actionable messages.
5. After `exportArchive`, the script verifies `codesign --verify --strict --deep --verbose=2 ".build/release/export/Codans.app"` and `spctl -a -v -t exec ".build/release/export/Codans.app"` (latter will say "rejected — not notarized" — that's expected and not an error here; M3 fixes it).
6. Add `apps/mac/Makefile` target `mac-archive` that calls `./scripts/release.sh archive`.

Acceptance: With a valid `Release.xcconfig`, `make mac-archive` produces `.build/release/export/Codans.app` whose `codesign -dv` shows `Authority=Developer ID Application: <name> (TEAM)`, `Authority=Developer ID Certification Authority`, `Authority=Apple Root CA`, and `Runtime Version` non-empty. `spctl` returns the not-notarized status (expected).

### Milestone 3: Notarization + stapling

By the end of this milestone, the same script can submit the signed `.app` to Apple's notary service and staple the returned ticket.

Work:

1. Document the one-time setup in `apps/mac/scripts/release.sh --help` output: `xcrun notarytool store-credentials codans-notary --key <p8-path> --key-id <id> --issuer <issuer-uuid>` once on the maintainer's Mac.
2. Add `apps/mac/scripts/notarize.sh` that takes a path to a `.app` or `.dmg`:
   - If `AC_API_KEY_ID` env var is set (CI mode), write the base64-decoded P8 key to a temp file with `mktemp -t codans-notary` and pass `--key`, `--key-id`, `--issuer`. Always `trap` to remove the temp file.
   - Else, pass `--keychain-profile codans-notary`.
   - Call `xcrun notarytool submit "$1" --wait` and capture the JSON. On `status: Accepted`, call `xcrun stapler staple "$1"`. On any other status, dump the log via `xcrun notarytool log <submission-id>` and exit non-zero.
3. Extend `release.sh` with a `notarize` subcommand and a top-level `release` subcommand that runs `archive` → `notarize` → (M4: `dmg`) end-to-end.

Acceptance: `./scripts/release.sh archive && ./scripts/release.sh notarize ".build/release/export/Codans.app"` exits 0 on a valid binary. `stapler validate ".build/release/export/Codans.app"` says "The validate action worked!". `spctl -a -v -t exec` now says "accepted".

### Milestone 4: DMG packaging (signed + notarized)

By the end of this milestone, `make mac-release VERSION=0.2.0` produces `Codans-0.2.0.dmg` that opens with the app on the left and an `/Applications` symlink on the right.

Work:

1. Add `apps/mac/scripts/make-dmg.sh` using `hdiutil` (no `brew` dep). Steps:
   - Create a staging dir `mktemp -d`.
   - Copy `Codans.app` into it.
   - `ln -s /Applications` inside the staging dir.
   - `hdiutil create -volname "Codans" -srcfolder <stage> -ov -format UDZO <out>.dmg`.
   - `codesign --sign "Developer ID Application: <name> (TEAM)" --timestamp <out>.dmg`.
   - Print SHA256 to stdout and to a sidecar `.sha256` file.

   No `.DS_Store` background-image dance in v1 — that's polish work. The plain DMG with `/Applications` symlink covers the support-cost win.
2. Extend `release.sh` with a `dmg` subcommand and call it from `release` after `notarize` (and notarize the DMG too — Apple notarizes both the inner `.app` and the DMG separately; the DMG ticket is stapled to the DMG, the `.app` ticket to the `.app`).
3. Add `Makefile` target `mac-release` that takes `VERSION` (defaults to `MARKETING_VERSION` from xcconfig) and calls `./scripts/release.sh release`.

Acceptance: `make mac-release` produces `apps/mac/.build/release/Codans-<version>.dmg` plus `Codans-<version>.dmg.sha256`. Open the DMG by hand on the development Mac — drag to `/Applications`, launch, no Gatekeeper prompt. `xcrun stapler validate` passes on both the DMG and the inner app.

### Milestone 5: Single-source version + Makefile front door

By the end of this milestone, bumping the version is a one-line edit, and the Makefile help text shows the release flow.

Work:

1. Edit `apps/mac/Configurations/mac-Info.plist`: replace `<string>0.1.0</string>` for `CFBundleShortVersionString` with `<string>$(MARKETING_VERSION)</string>`, and `<string>1</string>` for `CFBundleVersion` with `<string>$(CURRENT_PROJECT_VERSION)</string>`. Verify with `make mac-build && /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "<bundle>/Contents/Info.plist"` — should print `0.1.0` from the xcconfig.
2. Add `Makefile` target `mac-bump-version VERSION=x.y.z` that uses `sed -i ''` on `Configurations/Project.xcconfig` to update `MARKETING_VERSION` and increments `CURRENT_PROJECT_VERSION` by 1. Refuses without a `VERSION=` argument. Refuses if the working tree is dirty in `Configurations/`.
3. Update `apps/mac/Makefile` `help` target with the new `mac-archive`, `mac-release`, `mac-bump-version` lines.
4. Update top-level `Makefile` to delegate: `mac-archive`, `mac-release`, `mac-bump-version`.

Acceptance: `make mac-bump-version VERSION=0.2.0 && make mac-build` produces a bundle whose Info.plist reports `0.2.0`. The diff is exactly two lines in `Project.xcconfig`.

### Milestone 6: GitHub Actions release workflow on tag (Deferred — see DEC-7)

Deferred until a GitHub-hosted release channel exists. The work below is preserved verbatim so a future maintainer can execute it without re-discovering the cert-import + notarytool-in-CI pattern.

By the end of this milestone, pushing a `v*` git tag produces a draft GitHub Release with the DMG attached.

Work:

1. Add `.github/workflows/release.yml` triggered on `push: tags: [ 'v*' ]`. Single job on `macos-14` runner.
2. Workflow steps:
   - `actions/checkout@v4` with `submodules: recursive`.
   - Cache `apps/mac/.build/ghostty/` keyed on the ghostty submodule SHA + `apps/mac/scripts/build-ghostty.sh` hash + `mise.toml` hash. (Reuses the script's existing fingerprint logic; just gives the runner a head start.)
   - Set up `mise` via `jdx/mise-action@v2`.
   - Trust mise: `mise trust . apps/mac`.
   - Decode `${{ secrets.DEVELOPER_ID_CERT_P12_BASE64 }}` to a temp file. Create a temp keychain, import the cert with `${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}`, set as default, unlock for the duration of the run.
   - Write `apps/mac/Configurations/Release.xcconfig` from `${{ secrets.DEVELOPMENT_TEAM }}`.
   - `make mac-bootstrap mac-archive` (the workflow does not call `mac-bump-version` — the tag drives the version; the workflow asserts that the tag matches `MARKETING_VERSION` and aborts on mismatch).
   - `./apps/mac/scripts/release.sh notarize` with `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8` (base64) from secrets.
   - `./apps/mac/scripts/release.sh dmg`.
   - `softwareupdate --install-rosetta --agree-to-license` is NOT needed (we don't ship Intel — `arch -arm64` only — confirm in M2 archive output).
   - `gh release create "$GITHUB_REF_NAME" --draft --title "$GITHUB_REF_NAME" --notes-from-tag <dmg-path> <sha256-path>`.
3. Workflow asserts the working tree is clean after the build (catches a script that wrote into a tracked path).
4. Add `.github/workflows/ci.yml` if not present (lint + Debug build on PR) — out of scope for this plan if it already exists; just confirm.

Required GitHub Secrets (documented in `docs/operations/release-secrets.md` written in this milestone):
- `DEVELOPER_ID_CERT_P12_BASE64` — `base64 -i certs.p12`
- `DEVELOPER_ID_CERT_PASSWORD`
- `DEVELOPMENT_TEAM` — 10-char team ID
- `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8` (base64-encoded `.p8` contents)
- `KEYCHAIN_PASSWORD` — random per-run password for the temp keychain

Acceptance: `git tag v0.2.0 && git push origin v0.2.0` triggers the workflow; within ~25 minutes a draft release `v0.2.0` exists with `Codans-0.2.0.dmg` and `Codans-0.2.0.dmg.sha256` attached. Downloading and opening the DMG on a clean Mac shows no Gatekeeper warning.

### Milestone 7: Sparkle auto-update (deferred)

Captured for posterity. Sparkle integration adds:
- Sparkle SPM dep in `Project.swift`.
- `SUFeedURL` + `SUPublicEDKey` in `mac-Info.plist`.
- An `appcast.xml` published alongside the DMG (CI step).
- A "Check for Updates…" menu item.

This is its own design doc and exec plan when/if it lands. Recording the omission here so a future maintainer doesn't think we forgot.

## Concrete Steps

The full local release flow after all milestones land:

    # one-time, per maintainer Mac:
    cp apps/mac/Configurations/Release.xcconfig.example apps/mac/Configurations/Release.xcconfig
    $EDITOR apps/mac/Configurations/Release.xcconfig    # set your team ID
    xcrun notarytool store-credentials codans-notary \
      --key ~/keys/AuthKey_XXXX.p8 --key-id XXXX --issuer <uuid>

    # bump and ship:
    make mac-bump-version VERSION=0.2.0
    git commit -am "chore(mac): bump version to 0.2.0"
    git tag v0.2.0
    make mac-release      # locally — produces .build/release/Codans-0.2.0.dmg
    git push && git push --tags    # CI picks up the tag and re-produces the same DMG

Expected output of `make mac-release` (last lines):

    Notarization status: Accepted
    Stapled: .build/release/export/Codans.app
    Stapled: .build/release/Codans-0.2.0.dmg
    sha256: <hex>  Codans-0.2.0.dmg
    Done.

## Validation and Acceptance

End-to-end acceptance, exercised once on the maintainer's Mac and once via CI:

1. **Local release** — Run the Concrete Steps block. Resulting DMG opens cleanly on a separate, never-trusted Mac (or after `xattr -dr com.apple.quarantine ~ ; reboot` simulation). The app launches, the menu bar shows "Codans", `~/.local/bin/codans` does not exist yet but installing via the in-app prompt creates it, and `codans --version` reports `0.2.0`.
2. **CI release** — `git push origin v0.2.0` produces a draft GitHub Release whose DMG has the same SHA256 as the local one *minus* the embedded `_CodeSignature` timestamp (signatures differ between machines; that's expected). Stapled tickets validate. `gh release view v0.2.0` shows both assets.
3. **Regression** — `make mac-build` (Debug) still produces a launchable app on a contributor without a Developer ID certificate. `make mac-archive` on the same machine fails with the message "Developer ID Application certificate not found in keychain", not a cryptic xcodebuild error.

## Idempotence and Recovery

- `release.sh` uses `mktemp -d` for all staging; nothing leaks into the repo on Ctrl-C.
- `embed-codans.sh` uses `rm -rf` on the destination directory before copying — same pattern as `embed-git-wt.sh`. The script's `: "${SRCROOT:?…}"` guards prevent a stray run outside Xcode/xcodebuild from clobbering the wrong path.
- Re-running `make mac-release` against an already-notarized binary is safe: notarytool returns "already accepted" and stapler is a no-op on an already-stapled file.
- The CI workflow always creates the keychain with `mktemp` and removes it in `if: always()` — a failed run does not leave a Developer ID cert in the runner's persistent keychain (runners are ephemeral, but defense-in-depth).
- If notarization fails mid-flight (e.g., Apple service down): `release.sh notarize <path>` is re-runnable. The submission API is idempotent with respect to the same input.

## Artifacts and Notes

Notable transcript fragments to keep for verification:

- `codesign -dv --verbose=4 "Codans.app"` should show:

      Authority=Developer ID Application: <name> (TEAMID)
      Authority=Developer ID Certification Authority
      Authority=Apple Root CA
      Timestamp=<recent>
      Runtime Version=<macos sdk>
      Sealed Resources version=2 rules=…

- `spctl -a -v -t exec "Codans.app"` should print `accepted` after stapling.

- `xcrun notarytool log <submission-id>` JSON for the first run is worth pasting into the Surprises section if anything fails — the `issues` array is the diagnostic, not the human-readable summary.

## Interfaces and Dependencies

The release script surface (locked in M2–M4):

    ./apps/mac/scripts/release.sh archive
    ./apps/mac/scripts/release.sh notarize <path-to-app-or-dmg>
    ./apps/mac/scripts/release.sh dmg [--version X.Y.Z]
    ./apps/mac/scripts/release.sh release    # archive → notarize app → dmg → notarize dmg → staple both

Environment contract for the script (precedence: CLI flag > env > Release.xcconfig > xcconfig default):

- `DEVELOPMENT_TEAM`     — required, 10-char team ID
- `CODE_SIGN_IDENTITY`   — defaults to "Developer ID Application"
- `AC_API_KEY_ID`        — set in CI; absent locally
- `AC_API_ISSUER_ID`     — set in CI; absent locally
- `AC_API_KEY_P8`        — base64-encoded P8 contents; set in CI
- `KEYCHAIN_PROFILE`     — defaults to `codans-notary`; used when `AC_API_KEY_ID` is unset

External tools required (all on macOS-14 GitHub runners by default):

- `xcodebuild` (from Xcode 26+)
- `xcrun notarytool` (Xcode 13+)
- `xcrun stapler`
- `codesign`
- `hdiutil`
- `security`
- `gh` (CI only, for release create)
- `mise` (already required by bootstrap)

No new third-party dependency is introduced. `create-dmg` is intentionally avoided per DEC-1's implementation note.

## Open Questions

All three questions raised at draft time were resolved by Gump on 2026-04-28 and are kept here as a record:

1. **Apple Developer ID provisioned? — Yes.** Team ID, Developer ID Application `.p12`, and App Store Connect API key are available on the maintainer's Mac. M2–M5 unblocked.
2. **GitHub repo for releases? — No.** No GitHub-hosted release channel for v1; M6 deferred per DEC-7. Local `make mac-release` is the distribution path.
3. **PRODUCT_NAME with a space — accepted.** M1 sets `productName: "Codans"`; the on-disk bundle is `Codans.app`. M1 acceptance confirms no xcodebuild/Tuist regression from the embedded space.
