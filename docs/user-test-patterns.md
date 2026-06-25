# User-Test Patterns — codans

**Status:** Initial draft, written alongside [user-tests/notifications-v1-1.md](user-tests/notifications-v1-1.md). Expand as more features adopt the user-test pattern.

This document defines the project-wide conventions a user-test case must follow so the same case can be executed by a human dogfooder, an automated UI probe, or a runtime validator subagent without further translation.

## Surfaces and Tooling

codans is a native macOS app shipping three user-facing surfaces:

| Surface | Probe approach | Allowed selectors |
|---|---|---|
| **SwiftUI window UI** (main window, Settings window, sheets, alerts, context menus) | Manual visual probe by a human dogfooder; `XCUITest` for automated probes (preferred when the build target supports it) | Accessibility identifiers (`accessibilityIdentifier(_:)`), visible role + label (e.g., `Toggle("Sound", isOn:)` → role=switch, name="Sound"), or unambiguous on-screen text |
| **`codans` CLI** (JSON-RPC client → app) | Shell invocations with `codans …` and stdout/exit-code assertions | Subcommand name + flags; `--json` output where supported |
| **Persisted state files** (`~/.config/codans/{settings,catalog,notifications,detection-rules}.json`, plus log lines) | `jq` queries against file content; `log stream` / `Console.app` filters against `subsystem:"com.gumpw.codans.*"` | File path + JSON key path; log filter expression |

If a case cannot be expressed in one of these probe languages, the case is mis-scoped — either the assertion is implementation-internal (move to a unit test) or the surface needs a new accessibility identifier (raise it as a precondition / spec-amendment, do not work around with brittle selectors).

## Forbidden Selectors

- CSS classes, DOM positions, internal `data-test-*` ids invented inside a single case (any data-test id used in a case must be declared by the source code with a stable, documented name).
- Screen coordinates (`click at (314, 220)`) unless the case explicitly calls out window-chrome behaviour the macOS Accessibility tree cannot represent.
- Internal symbol names — never name a Swift type, function, file path, or module in a case. Black-box only.
- Sleep timers as a proxy for state ("wait 3 seconds then assert") — wait on an observable signal (badge label change, file mtime, log line).

## Ready Signals

Every case that drives the app must wait on a ready signal before executing steps:

| Surface | Ready signal |
|---|---|
| App launched | Dock icon visible AND main window's worktree status bar contains the bell button |
| Settings window open | `Settings → Notifications` section header is visible AND the macOS-permission status row has resolved to one of `Authorized` / `Denied` / `Not yet asked` |
| Pane attached | Pane chrome shows the prompt cursor OR the spinner "Spinning up shell…" has disappeared |
| Notification emitted | Either: a Dock badge label change, a log line under `subsystem:"com.gumpw.codans.notifications"` `category:"coordinator"` with a recognised verb (`posted`, `drop`), or a row in `~/.config/codans/notifications.json`'s `entries` array (whichever the case names) |

## Fixture Seeding

Files are placed under the user's `~/.config/codans/` before app launch. Each case names the exact files it seeds; the runner is responsible for backing up and restoring the user's real files around the case.

```
~/.config/codans/
  settings.json            — owned by SettingsStore; seed-able before launch
  catalog.json             — owned by CatalogStore; seed-able before launch
  notifications.json       — owned by NotificationStore; seed-able before launch
  detection-rules.json     — owned by the (forthcoming) mute-rules surface
```

Fixtures shared across cases live under `docs/user-tests/_shared/fixtures/`. Case-local fixtures live under `docs/user-tests/<feature>/fixtures/`.

## Time and Clock

Cases do not assume real wall-clock time. Where a case needs "now" semantics (e.g., the 1-second keystroke window, the 30-second idle threshold), the case specifies the wait via an observable signal or an injected fake clock — never `sleep 30`.

For cases that genuinely require duration progression (a command running for ≥10 seconds to cross a threshold), the case names the lower-bound wait and ties the assertion to an observable event (Dock badge appears) rather than the wall-clock value.

## Artifacts on FAIL

Every case lists what to capture on FAIL. Defaults that apply to every case unless overridden:

- `screenshot.png` — full-window screenshot at first failed assertion.
- `console.log` — `log stream --predicate 'subsystem == "com.gumpw.codans.notifications"' --last 5m` output around the failure.
- For probes that touched a state file: a copy of the file at failure time, named `<file>.snapshot.json`.

## Personas

Personas are reusable across features. The shared registry is `docs/user-tests/_shared/personas.yaml`. A persona is a stable identity (name + role + typical configuration) the case can refer to without re-specifying. New personas added during authoring are recorded in the case's "Personas / Fixtures Added" section.

## Out of Scope (deferred)

- Visual regression / snapshot diffing of arbitrary view layouts. Cases assert observable state, not pixel fidelity.
- Performance budgets. Cases that need a perf SLO (latency under N ms, FPS above N) cite the existing perf-budget gate instead and explicitly mark the AC as "not user-observable".
- Cross-version migration tests beyond what a fixture seed expresses. Migration coverage lives in the relevant module's unit suite.

## Knowledge Persistence

Operational facts discovered during validation runs (append fact, not test assertions):

- **No interactive-GUI automation surface exists in the agent environment** (no computer-use / screenshot / XCUITest scheme). SwiftUI-window assertions (rendered a11y values, on-screen placement, live row updates, context-menu contents) are therefore **deferred to a human dogfooder** in automated validation — record them `blocked` with the underlying logic verified by the reducer/integration/Codable suites, never a faked PASS.
- **`wt` and `/bin/bash` are bundled in the Codans test host**, so `WorktreeLifecycleIntegrationTests` run for real (real `git worktree add` + setup-script subprocess; ~0.5–1.4 s each) — the strongest black-box evidence tier for worktree-lifecycle assertions.
- **Swift Testing prints a spurious `Executed 0 tests` line** under `xcodebuild test`; the authoritative count is the `Test run with N tests passed` line. Do not read "Executed 0 tests" as a skipped suite. **Function-level `-only-testing 'CodansTests/<Suite>/<func>'` silently matches 0 tests** under this Xcode 26 / Swift Testing setup (a vacuous `Executed 0 tests` → `TEST SUCCEEDED` false-green) — filter at **suite level** (`CodansTests/<Suite>`) and read the `Test run with N tests passed` count to confirm the suite actually ran.
- **Do not drive the live `codans` CLI / installed `Codans.app` for validation**: the running instance is typically built from a different worktree and owns the `~/.config/codans/{settings,catalog}.json` socket; driving it mutates the user's real state with no reset boundary. The CLI is a thin RPC client to the socket-owning app, so it cannot probe an arbitrary build in isolation.
- **Build is heavy + stale-Tuist-path hazard**: a stale `apps/mac/Tuist/.build` pointing at an old worktree path breaks `xcodebuild`; fix with `rm -rf apps/mac/Tuist/.build && make mac-generate` then rebuild.
- **Worktree-creation in-progress UI exposes a stable, unit-pinned accessibility vocabulary** that a SwiftUI-window probe (human dogfooder or XCUITest) keys on — assert observable STATE via these, never the decorative shimmer/skeleton sweep (which is Reduce-Motion-fragile and carries no meaning). The strings are a fixed contract (renaming one breaks a unit test):
  - Sidebar in-progress row — name in-progress-vs-settled accessibility **value**: `in-progress` (creating, either leg) / `settled` (failed; a successful creation removes the row entirely, so a surviving pending row only ever reports `settled` on failure). Per-leg stage **value** rides the **status / second-line leaf** (the caption-font `Text` below the display name): `creating` (git-add) / `setupScript` / `failed`. Both the name leaf (in-progress/settled) and the status leaf (stage) are probeable children under the row's `.contain` container. Both the setup-phase glyph and the creating-leg `ProgressView()` spinner are `accessibilityHidden` (decorative); the stage value on the status leaf is the authoritative signal.
  - Detail loading view — accessibility **identifiers**: `loading-view container` (root while creating/removing) with `skeleton-left` (branch/icon-identity placeholder) + `skeleton-middle` (status placeholder) inside it; `streaming-output` on the 5-line head-truncated command tail (present from the first frame via a "Creating worktree in <repo>…" fallback, so probe it without waiting on git output); the operation/command chip carries the phase-driven label as its accessibility value (`git worktree add` while creating, the configured setup command or `setup script` while running setup). On failure the root drops the `loading-view container` id and adopts `loading-failure` (label "Worktree creation failed", error message as value) — the two ids are MUTUALLY EXCLUSIVE, so a probe asserts exactly one per state and the decorative warning glyph stays `accessibilityHidden`.
- **`RootFeatureTests/worktreeHeadChangedForwardsToBranchSwitcherWhenIDMatches` (FU-T10) is a pre-existing flaky test, not a regression signal.** It injects no `ImmediateClock`, so `await store.receive(\.branchSwitcher.headChangedForCurrentWorktree)` waits on the live clock within TCA's default 1.0 s real-time window; under parallel-test CPU load the in-flight effect misses that window → `Expected to receive a matching action, but received none after 1.0 seconds`. It therefore FAILS under heavy parallel load (a full multi-suite run) but PASSES when `RootFeatureTests` runs as a lone suite (`-only-testing:CodansTests/RootFeatureTests`, lighter parallel load). NOTE: the function-level selector for it matches 0 tests (see the Swift-Testing gotcha above), so demonstrate its green via the **suite-alone** run, not a function isolation. The BranchSwitcher routing under test and the test body are unchanged since before M1-seal; exclude it from new-failure counts. Durable fix: inject an `ImmediateClock` (mirroring the sibling at `RootFeatureTests.swift:911`) or set an explicit `receive` timeout.
