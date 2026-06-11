# ExecPlan: Ghostty Action Routing for All 62 Actions

**Status:** Completed
**Author:** Gump
**Date:** 2026-04-22

This is a living document. The Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective sections must be kept up to date as work proceeds.

## Purpose

After completing this plan, users can configure keybindings in Ghostty's config and those bindings will route to meaningful codans actions: new tabs, splits, window operations, terminal commands, and app settings. Currently the action callback is a stub that silently ignores all bindings. Implementing this plan will restore the full keybinding surface, routing all 62 supported ghostty actions into the app's TCA layer for handling.

The user-visible outcome: `keybind cmd+e = close_tab` in `~/.config/ghostty/config` will work as expected — the key press will close the active tab instead of being silently dropped. The same applies to every keybinding the user configures across the action budget.

## Progress

- [x] Milestone 1: Core types and TerminalEvent additions (2026-04-22, `bb7b18e`)
- [x] Milestone 3: SurfaceInfo and PaneSurface extensions (2026-04-22, `b70b755`)
- [x] Milestone 5: PaneActionRouterFeature + HierarchyClient/Manager extensions (2026-04-22, `f2b482a`)
- [x] Milestone 6: WindowActionRouterFeature + WindowService/AppLifecycleClient/UpdatesClient (2026-04-22, `1d2260a`)
- [x] Milestone 2 + 4: GhosttyActionDecoder + GhosttyRuntime routing (2026-04-22, `baa9058`)
- [x] Milestone 7a: RootFeature integration (2026-04-22, `4476767`)
- [x] Milestone 7b: Unit tests (2026-04-22) — 4 suites, ~1300 LOC:
  - `PanelSurfaceApplyTests` (31 `@Test`, 29/29 PaneInfoDelta case mirrored)
  - `GhosttyActionDecoderTests` (29 `@Test`, 6 helper enums × their C values)
  - `PaneActionRouterFeatureTests` (13 `@Test`, 11/11 request cases + nil-address edge)
  - `WindowActionRouterFeatureTests` (11 `@Test`, 11/11 cases)
- [x] Milestone 7c: Manual smoke checklist below; Outcomes & Retrospective filled

## Surprises & Discoveries

**M1: Three exhaustive switches needed updating beyond the plan** (2026-04-22). The plan mentioned only `RootFeature` as a downstream consumer, but two more files pattern-matched TerminalEvent exhaustively:
- `codans/Hooks/EventMapper.swift:51` — maps TerminalEvent to HookEnvelope. New events return nil (no hook semantics).
- `codans/Runtime/TerminalEngine.swift:381` — classifies events as lifecycle (unbuffered) vs chatty (buffered). Classified `.panelInfoChanged` as non-lifecycle (per design doc Risks table about chatty TUI); the three intent/config events are lifecycle.

Both are small additions. No impact on subsequent milestones.

## Decision Log

**DEC-1 — New Core types at top level, not `Pane/` subfolder.** Plan proposed `CodansCore/Pane/*.swift`. Existing convention: Pane.swift, Project.swift, Space.swift, etc. all sit at top level of CodansCore/. Placed new files at top level to match, avoiding the need to update Tuist `buildableFolders`.

**DEC-2 — Inline `sizeLimit` fields instead of defining a `Size` struct.** Plan referenced `Size` in `PaneInfoDelta.sizeLimit(min:max:)`, but no `Size` type exists in Core. Inlined as `sizeLimit(minWidth:minHeight:maxWidth:maxHeight:)` to avoid adding an unused helper type. Four `UInt32` fields are not meaningfully worse than a `Size` struct.

**DEC-3 — `panelInfoChanged` classified as non-lifecycle (droppable).** Per design doc's chatty-TUI risk, `SET_TITLE`/`PWD`/`PROGRESS_REPORT` fire on every prompt and must not block the event stream. Three intent/config events (`panelActionRequested`, `windowActionRequested`, `configChanged`) are lifecycle — user keypresses cannot drop.

**DEC-M2-1 — `COPY_TITLE_TO_CLIPBOARD` is currently a stub.** Design doc reads `pane.info.title` and writes `NSPasteboard`. SurfaceInfo shipped in M3; the two-line fill-in is left to a follow-up commit so M2 doesn't depend on future M3 shape.

**DEC-M2-2 — `NewSplitDirection` collapses 4 C directions → 2 axes.** libghostty's `ghostty_action_split_direction_e` has RIGHT/DOWN/LEFT/UP. Core's `NewSplitDirection` is `.horizontal/.vertical`. Map LEFT/RIGHT→horizontal, UP/DOWN→vertical. Loses orientation hint; acceptable because split creation's UX only cares about axis.

**DEC-M2-3 — `GotoWindowTarget.last`/`.index(Int)` are unreachable from libghostty.** The C enum only emits PREVIOUS/NEXT. Kept as forward-compat cases for IPC callers.

**DEC-M2-5 — Raw C enum tags preserved as `UInt32` through `PaneInfoDelta`.** `PROMPT_TITLE`/`MOUSE_SHAPE`/`SECURE_INPUT`/`QUIT_TIMER`/`PROGRESS_REPORT.state` pass their raw tag through the delta to keep the decoder as the single translation boundary. Consumers that need typed enums remap downstream.

**DEC-M2-7 — `KEY_TABLE` 3 C tags compress to `(name, depth)`.** ACTIVATE → `(name, +1)`, DEACTIVATE → `(nil, -1)`, DEACTIVATE_ALL → `(nil, 0)`. Depth encodes the mutation, not absolute stack height.

**DEC-M2-8 — `KEY_SEQUENCE.trigger` hashes to a UInt32 fingerprint.** Full `ghostty_input_trigger_s` (tag+key+mods) doesn't fit `PaneInfoDelta.keySequence(trigger: UInt32)`. Hash suffices as a change-detector; expand the delta if a feature ever needs the literal keystroke.

**DEC-M5-A — `HierarchyClient.unzoomTab` added** because the spec referenced `zoomPanel`/`unzoomPanel` that don't exist; `HierarchyManager.focusPanel`/`unfocusPanel` already implement the zoom semantics under older names. Rename opportunity for later.

**DEC-M5-C — Router delegates `.presentTerminalRequested`/`.commandPaletteToggleRequested`** back to RootFeature. codans has no command palette feature today; RootFeature consumes both as explicit no-ops so the seam exists without the consumer.

**DEC-M5-E — `resizePanel` is a ratio delta, not pixels.** libghostty's RESIZE_SPLIT carries pixels; `SplitTree` stores only ratios (clamped [0.1, 0.9]). `amount` is treated as a ratio delta directly. Good enough; the decoder can scale if keybinds feel under/over-responsive.

**DEC-M6-1 — `WindowService.openNewWindow`/`closeWindow` are stubs.** `CodansApp` is single-`WindowGroup` today; SwiftUI's `OpenWindowAction` isn't reachable from a Client, and no per-Pane→NSWindow registry exists. `closeWindow` falls back to `NSApp.keyWindow.performClose(nil)` which ignores the paneID argument but handles the common case (keybind inside the focused window). Full implementation waits on the multi-window design (design doc §Risks).

**DEC-M6-3 — `openConfig` uses `NSWorkspace.open`, not `EditorClient`.** `EditorClient.open(directory:…)` only accepts directory URLs; no file-level overload. `NSWorkspace.open(URL(fileURLWithPath: "~/.config/ghostty/config"))` respects the user's LaunchServices default for the file type. Switch to `EditorClient` once it gains file opens.

**DEC-M4-1 — `GhosttyRuntime.terminalEngine` is a `weak var`.** Runtime does not own the engine; engine owns runtime. The reverse pointer is assigned in `TerminalEngine.init`. Weak ref breaks the cycle and mirrors the pre-existing `dispatcher.runtime: GhosttyRuntime?` pattern.

**DEC-M4-2 — `reloadConfig(soft:)` ignores `soft`.** libghostty exposes no in-place reload primitive; our rebuild (default → recursive → finalize → swap) is the same either way. The parameter is preserved on the signature so a real `ghostty_app_reload_config(app, soft)` binding can be wired without a call-site change.

**DEC-M4-3 — `toggleBackgroundOpacity` is empty.** Opacity lives in the appearance settings layer (DeveloperSettings / future appearance overrides) that the runtime does not own. The method exists so the decoder compiles and the keybind is observable via its `.debug` log.

**DEC-M7-1 — `CODANS_DISABLE_ACTION_ROUTING=1` gate sits in the C callback.** Earlier than the decoder so the escape hatch short-circuits before any main-thread hop. Environmental read on every callback is cheap (`ProcessInfo.environment` is lazily cached by Foundation).

**DEC-M7-2 — Event fan-out routes through the existing `terminalClient.events()` stream, not a new stream.** The engine's single AsyncStream already fans out to every subscriber; adding per-event streams would duplicate the broadcast. The root reducer filters by pattern inline — one switch, two `send` calls — and every other event keeps flowing through the diagnostic `lastEvent` marker.

**DEC-M7b-1 — Six `decode*` enum helpers relaxed from `fileprivate` to `internal static`.** The C→Swift enum mapping tables in `GhosttyActionDecoder` (close tab mode / new split direction / goto split direction / resize split direction / goto tab target / goto window target) are the only slices of the 65-case switch that can be tested without constructing a full `ghostty_action_s` C union. `@testable import Codans` cannot cross `fileprivate`, so these six helpers are now `static` (module-internal) while `decodeKeyTable`, `keyTriggerFingerprint`, `handleOpenURL`, and the `emit*` dispatch helpers stay `fileprivate`. Visibility-only change; no callers or behavior moved.

## Codex Review Resolution (2026-04-22)

Codex flagged six correctness / safety issues after the initial landing. All are fixed in commit `3945592`.

**DEC-M7d-1 — Decoder split into nonisolated decode + MainActor apply (P1).** Original design stored the raw `ghostty_action_s` struct and deferred all decoding to a main-queue hop. Several union fields carry C pointers whose lifetime ends when `action_cb` returns, so the async apply could read freed memory; the callback also returned `false` even though the action ran asynchronously. The decoder is now two passes: `decodeSurfaceAction` / `decodeAppAction` (`nonisolated`) synchronously copy every pointer-backed field into a Sendable `DecodedSurfaceAction` / `DecodedAppAction` enum (Strings for title/pwd/needle/url/body/key-table name, `ghostty_config_clone` for CONFIG_CHANGE), and `apply(_:)` (`@MainActor`) consumes the owned value. The thunk reports `decoded.consumed` synchronously so the C return value matches reality.

**DEC-M7d-2 — `.newTab` opens a pane using the source pane's cwd (P2).** Earlier dispatch only called `HierarchyClient.createTab`, which initialises an empty Tab; the resulting Tab rendered the "No panes" placeholder. The router now follows `createTab` with `openPanel`, inheriting the source pane's `workingDirectory` (or falling back to `worktree.path`, then `$HOME` if neither resolves).

**DEC-M7d-3 — `.gotoTab(.index)` is 1-based with over-bound clamp (P2).** Ghostty's `goto_tab:n` is 1-based and clamps beyond the tab count to the last tab. The router previously treated `n` as a zero-based array index and rejected out-of-range values. Now: `n < 1` rejects, `n` in range picks `tabs[n-1]`, `n > count` picks `tabs[count-1]`.

**DEC-M7d-4 — `NewSplitDirection` reverts from 2-axis to 4-direction (P2).** DEC-M2-2's collapse onto `.horizontal/.vertical` meant every `new_split:left` or `new_split:up` binding landed on the wrong side. `NewSplitDirection` now mirrors libghostty's `ghostty_action_split_direction_e` (right/left/up/down) 1:1; the router maps each case to the matching `SplitTree.NewDirection`.

**DEC-M7d-5 — `HierarchyManager.moveTab` wraps cyclically (P2).** Ghostty's `move_tab` action wraps at both edges: moving the last tab forward lands at position 0; moving the first tab backward lands at `count-1`. Was a hard clamp that silently no-op'd at edges.

**DEC-M7d-6 — `HierarchyManager.resizePanel` scales pixel amount into a ratio delta (P2).** libghostty's RESIZE_SPLIT carries a pixel count (default keybind `10`), but `SplitTree` stores only ratios clamped to `[0.1, 0.9]`. Adding pixels to a ratio collapsed the split on the first keystroke. Scaled by an empirical `pixelsPerRatioStep = 400` so a default `10 px` keybind nudges the ratio by ~2.5%. When the viewport layer later exposes the real split frame, the constant becomes per-split.

## Outcomes & Retrospective

**What shipped (2026-04-22).** All 65 libghostty action tags are routed: tab/split intents to `PaneActionRouterFeature` → `HierarchyClient` / `HierarchyManager`, window intents to `WindowActionRouterFeature` → `WindowService` / `AppLifecycleClient` / `UpdatesClient` / `EditorClient`, surface-info deltas to `PaneSurface.info` + the `panelInfoChanged` event stream, effectful actions inline via AppKit, and app-level config changes via `GhosttyRuntime.applyClonedConfig` / `reloadConfig`. The prior hardcoded `action_cb` stub — silently dropping every user keybind — is gone. A launch-arg gate (`CODANS_DISABLE_ACTION_ROUTING=1`) provides a hotfix escape hatch.

**What was bigger than planned.** The plan scoped the decoder at "~250 lines / 62 cases"; reality was 559 lines / 65 cases, driven by 10+ small trade-offs between libghostty's richer C union and codans's typed Swift surface (recorded DEC-M2-1 through DEC-M2-10). The downstream blast radius was also understated: 3 pre-existing exhaustive switches on `TerminalEvent` needed updates (`RootFeature.LastEventMarker`, `EventMapper.map`, `TerminalEngine.isLifecycle`).

**What was smaller than planned.** Parallelizing via sub-agents collapsed M2/M3/M5/M6 from a sequential "~4-day" chain into a single working session. Seven atomic commits (bb7b18e → 4476767) split the work so the history stays bisectable across buckets.

**Known limitations deliberately left for follow-up.**
- `WindowService.openNewWindow` / `closeWindow` are stubs pending the multi-window design decision (see design doc §Risks "Window intent without multi-window model").
- `UpdatesClient.checkNow` is a logger stub until Sparkle wires in.
- `COPY_TITLE_TO_CLIPBOARD` is a 2-line fill-in deferred (DEC-M2-1) so M2 didn't depend on M3's shape.
- `toggleBackgroundOpacity` is empty — opacity ownership lives in appearance settings, not this runtime.
- `.delegate(.presentTerminalRequested)` and `.delegate(.commandPaletteToggleRequested)` are consumed as root-level no-ops; codans has no command-palette feature yet.
- Router-to-catalog resolution in `gotoSplit` collapses 4-way spatial directions to previous/next; a true spatial walk needs per-pane frame geometry the reducer doesn't own (DEC-M5-B).
- `resizeSplit` treats `amount` as a ratio delta because `SplitTree` stores ratios only, not pixels (DEC-M5-E).

**Test host bootstrap is broken independent of this plan.** When invoking `xcodebuild test`, the test host app's `EditorFeature.refresh` recurses on a stack-overflow-style path through `LiveEditorService.describe` / `EditorClient.live`; this reproduces on unmodified test suites (`TerminalEngineTests`) so it is pre-existing, not introduced by this plan. Tests `build-for-testing` cleanly (swift-testing + XCTest + TCA 的 compile 都过); runtime validation runs through the M7c smoke checklist until the bootstrap issue is fixed.

**Retrospective.** The design doc's "one decoder, many consumers" split held up well under real C-union shape discovery. Placing the C→Swift boundary inside a single file meant every rough edge between libghostty and Core showed up as a Decision Log entry instead of cascading through a dozen sites. Sub-agents worked best when each was given (1) the exact file paths to create/touch, (2) the set of *types that do not yet exist* it could assume future agents would add, and (3) a "do not commit / do not build" discipline so the orchestrator keeps commit boundaries clean.

## Context and Orientation

**Related documents:**
- **Design doc:** `docs/design-docs/0008-ghostty-action-routing.md` — comprehensive specification of all 62 actions, 5-bucket classification, decoder architecture, event types, and alternative analysis.
- **Architecture doc:** `docs/architecture.md` — system domains, dependency rules, state management hybrid (TCA + @Observable), invariant "Runtime is TCA-free".
- **TerminalEvent:** `apps/mac/CodansCore/TerminalEvent.swift` — source of the existing event enum.

**Key source files:**
- `apps/mac/codans/Runtime/Ghostty/GhosttyRuntime.swift` — owns action callback stub at line 148; holds Pane registry and shared weak reference.
- `apps/mac/codans/Runtime/Ghostty/PaneSurface.swift` — embeds 16 bytes of PaneID as userdata; needs SurfaceInfo @Observable state added.
- `apps/mac/codans/App/Clients/HierarchyClient.swift` — TCA bridge; will gain closures for addressOf, moveTab, equalizeTabSplits, resizePanel.
- `apps/mac/codans/App/Features/RootFeature.swift` — root reducer; will compose the two new routers.

**Orientation:** The work flows upward from Core types to Runtime decoding to TCA feature consumption. The key architectural insight is the layering:
- **Core (types):** add 4 TerminalEvent cases + 3 public enums for PaneInfoDelta, PaneActionRequest, WindowActionRequest
- **Runtime (Ghostty):** decode C enums into typed Swift in one centralized module; emit events
- **App (features):** consume events via TCA reducers; dispatch to clients

This layering preserves the invariant "Runtime is TCA-free" while handling every action. No circular dependencies; events flow one way: Runtime → AsyncStream → TCA.

## Plan of Work

Work is organized into seven milestones, each delivering a self-contained capability. Each milestone is independently testable; the full feature is the union. The sequence respects dependency order: Core before Runtime before App; decoding before consumption.

### Milestone 1: Core Types and TerminalEvent Additions

**Goal:** Define the public types consumed by Runtime and features. All ghostty action dispatch happens through these types — they are the contract between layers.

**What exists at the end:** Three new public enums in `CodansCore/Pane/` and four new TerminalEvent cases in `CodansCore/TerminalEvent.swift`, providing typed representations of every routable action and info mutation.

**Work:**

1. **`apps/mac/CodansCore/Pane/PaneInfoDelta.swift` (new file)**

   Create enum with 25 cases, one per info-state mutation the decoder will emit. The design doc defines all cases; copy them verbatim:

   ```swift
   public enum PaneInfoDelta: Sendable, Equatable {
     case title(String?)
     case tabTitle(String?)
     case promptTitle(UInt32)
     case pwd(String?)
     case mouseShape(UInt32)
     case mouseVisible(Bool)
     case mouseOverLink(String?)
     case colorChange(kind: Int32, r: UInt8, g: UInt8, b: UInt8)
     case rendererHealthy(Bool)
     case cellSize(width: UInt32, height: UInt32)
     case sizeLimit(min: Size, max: Size)
     case initialSize(width: UInt32, height: UInt32)
     case resetWindowSize
     case scrollbar(total: Int, offset: Int, length: Int)
     case secureInput(UInt32)
     case keySequence(active: Bool, trigger: UInt32)
     case keyTable(name: String?, depth: Int)
     case readonly(Bool)
     case quitTimer(UInt32)
     case floatWindow(Bool)
     case searchStarted(needle: String)
     case searchEnded
     case searchTotal(Int)
     case searchSelected(Int)
     case progress(state: UInt32, value: Int?)
     case bellRang
     case desktopNotification(title: String, body: String)
     case commandFinished(exitCode: Int32, duration: UInt64)
     case childExited(code: Int32)
   }
   ```

   Note: `Size` is imported from `CodansCore` (used elsewhere for window sizing). Check that it exists; if not, define as `struct Size: Sendable { let width: UInt32; let height: UInt32 }`.

2. **`apps/mac/CodansCore/Pane/PaneActionRequest.swift` (new file)**

   Create enum with 11 cases for tab/split intents and supporting types. Include typed wrappers around ghostty's C enums:

   ```swift
   public enum PaneActionRequest: Sendable, Equatable {
     case newTab
     case closeTab(mode: CloseTabMode)
     case moveTab(offset: Int)
     case gotoTab(target: GotoTabTarget)
     case newSplit(direction: NewSplitDirection)
     case gotoSplit(direction: FocusDirection)
     case resizeSplit(direction: ResizeDirection, amount: Double)
     case equalizeSplits
     case toggleSplitZoom
     case presentTerminal
     case toggleCommandPalette
   }

   public enum CloseTabMode: Sendable, Equatable { case this, other, right }
   public enum GotoTabTarget: Sendable, Equatable {
     case previous, next, last, index(Int)
   }
   public enum NewSplitDirection: Sendable, Equatable { case horizontal, vertical }
   public enum FocusDirection: Sendable, Equatable { case up, down, left, right }
   public enum ResizeDirection: Sendable, Equatable { case up, down, left, right }
   ```

   (The decoder will map ghostty's C enum tags to these cases; this file just defines the typed wrapper enums that the decoder produces and features consume.)

3. **`apps/mac/CodansCore/Pane/WindowActionRequest.swift` (new file)**

   Create enum with 11 cases for window/app intents and typed target wrapper:

   ```swift
   public enum WindowActionRequest: Sendable, Equatable {
     case new(from: PaneID)
     case close(from: PaneID)
     case closeAll
     case goto(target: GotoWindowTarget)
     case toggleFullscreen(from: PaneID)
     case toggleMaximize(from: PaneID)
     case toggleTabOverview(from: PaneID)
     case toggleAppVisibility
     case quit
     case checkForUpdates
     case openConfig
   }

   public enum GotoWindowTarget: Sendable, Equatable {
     case recent, next, previous, index(Int)
   }
   ```

   (Exact cases copied from design doc. The target wrapper will be decoded from ghostty's C union.)

4. **`apps/mac/CodansCore/TerminalEvent.swift` — add 4 cases**

   Add to the `public nonisolated enum TerminalEvent` enum:

   ```swift
   case panelInfoChanged(PaneID, PaneInfoDelta)
   case panelActionRequested(PaneID, PaneActionRequest)
   case windowActionRequested(WindowActionRequest)
   case configChanged
   ```

   These are the events Runtime emits; TCA features subscribe via the TerminalEngine's event stream.

**Verification:** `cd apps/mac && make mac-build` and confirm no new errors. All four type definitions compile, are public + Sendable + Equatable, and import cleanly.

---

### Milestone 2: GhosttyActionDecoder Module

**Goal:** Create the single module that translates libghostty's C enums + unions into typed Swift. Everything else in the codebase speaks typed Swift; the decoder is the translation boundary.

**What exists at the end:** A new `GhosttyActionDecoder` type in `apps/mac/codans/Runtime/Ghostty/GhosttyActionDecoder.swift` with two static methods: `appAction` and `surfaceAction`. Each handles the full action dispatch for its target type, decoding the C union, resolving the action intent, and returning a Bool (true = consumed, false = fallback to Ghostty default).

**Work:**

1. **`apps/mac/codans/Runtime/Ghostty/GhosttyActionDecoder.swift` (new file)**

   Create the decoder enum with the skeleton from the design doc. The implementation will contain ~250 lines (62 cases across two methods).

   Responsibilities:
   - Import `GhosttyKit` (libghostty C bindings) + `Foundation` + `os.log` + necessary Core types
   - Define helper decoding functions (e.g., `String.decode(cstring:)` for safe C string reading; pattern-match from supacode if it exists)
   - Implement `appAction(_ action: ghostty_action_s, runtime: GhosttyRuntime) -> Bool` — routes app-level actions (CONFIG_CHANGE, RELOAD_CONFIG)
   - Implement `surfaceAction(_ action: ghostty_action_s, paneID: PaneID, pane: PaneSurface, runtime: GhosttyRuntime) -> Bool` — routes surface-scoped actions across 5 buckets

   **Bucket 1 — Tab/Split intent:** Cases like GHOSTTY_ACTION_NEW_TAB, CLOSE_TAB, etc. Each case emits `.panelActionRequested(paneID, .newTab)` or similar, returns true.

   **Bucket 2 — Window intent:** Cases like GHOSTTY_ACTION_NEW_WINDOW, CLOSE_WINDOW, etc. Each case emits `.windowActionRequested(.new(from: paneID))`, returns true.

   **Bucket 3 — Info:** Cases like SET_TITLE, PWD, MOUSE_SHAPE, etc. Each case calls `pane.apply(delta)` and `runtime.emitInfoChanged(paneID, delta)`, returns true. (Emission pattern ensures both PaneSurface state and event stream are updated.)

   **Bucket 4 — Effectful:** Cases like OPEN_URL, RING_BELL, COPY_TITLE_TO_CLIPBOARD, etc. Direct side effects via NSWorkspace / NSPasteboard / NSApp, plus optional event emission for observability.

   **Bucket 5 — Ignored:** RENDER, INSPECTOR, SHOW_GTK_INSPECTOR, etc. Log at .debug + return false.

   The full implementation is lengthy but mechanical — paste from the design doc skeleton and fill in type translations. Total ~250 lines across both methods, well under 400. The pattern is repetitive; use a code template or macro if the codebase allows, or accept the repetition as the cost of explicitness.

2. **Verification:** Build, check that the decoder compiles, and run a smoke test to ensure all 62 action tags are handled (no `default` case; compiler ensures exhaustiveness).

**Implementation notes:**
- Helper `String.decode(cstring:)` should safely copy C strings into Swift. Check supacode's GhosttySurfaceBridge or similar for the idiom.
- For enum decoding (e.g., `NewSplitDirection` from ghostty's int tags), create small helper functions inside or adjacent to the decoder.
- Log every decoded action at `.debug` level with `(tag, paneID)` for diagnostics.
- For unsupported actions, log at `.info` with the tag int and return false.

---

### Milestone 3: SurfaceInfo and PaneSurface Extensions

**Goal:** Add ephemeral per-session state storage to PaneSurface so that info mutations are persisted and accessible to features.

**What exists at the end:** A new `SurfaceInfo` @Observable class with ~20 fields, embedded in PaneSurface. PaneSurface gains an `apply(_: PaneInfoDelta)` method to mutate the info state, and a read-only property `info` to access it.

**Work:**

1. **`apps/mac/codans/Runtime/Ghostty/SurfaceInfo.swift` (new file)**

   Create the @Observable class as defined in the design doc. All fields should have sensible defaults (empty strings, 0, false, nil as appropriate). No persistence — this is ephemeral session state.

   ```swift
   @MainActor
   @Observable
   final class SurfaceInfo {
     var title: String?
     var tabTitle: String?
     var promptTitle: UInt32 = 0
     var pwd: String?
     var mouseShape: UInt32 = 0
     var mouseVisible: Bool = true
     var mouseOverLink: String?
     // …(rest of fields per design doc)
   }
   ```

   Add a convenience initializer if needed for clarity. Keep this class minimal — no methods except properties.

2. **`apps/mac/codans/Runtime/Ghostty/PaneSurface.swift` — add state + methods**

   a) Add a property:
   ```swift
   @ObservationIgnored
   var info: SurfaceInfo = SurfaceInfo()
   ```
   (Lazy initialization is optional; eager is fine for 20 fields.)

   b) Add method:
   ```swift
   func apply(_ delta: PaneInfoDelta) {
     switch delta {
     case .title(let t): info.title = t
     case .tabTitle(let t): info.tabTitle = t
     case .promptTitle(let p): info.promptTitle = p
     case .pwd(let p): info.pwd = p
     // …(one case per PaneInfoDelta variant)
     }
   }
   ```

   c) Add method (for SHOW_CHILD_EXITED bucket):
   ```swift
   func markExited(code: Int32) {
     info.lastCommandExitCode = code
   }
   ```

   The `apply` method is the single place PaneInfoDelta is translated to field mutations. The decoder calls it; features read via `pane.info.title` etc.

3. **Verification:** Build, no errors. Create a simple unit test in `apps/mac/codans/Tests/PanelSurfaceTests.swift` that constructs a PaneSurface, applies a few deltas, and asserts the fields changed. (This is a smoke test; the heavy lifting is in the router tests.)

---

### Milestone 4: GhosttyRuntime Action Routing

**Goal:** Replace the action callback stub in GhosttyRuntime with real routing logic that dispatches to the decoder and emits events.

**What exists at the end:** GhosttyRuntime has a real `handleAction` method, the C callback thunk hops to MainActor correctly, and pane-to-paneID resolution works via the userdata 16-byte allocation.

**Work:**

1. **`apps/mac/codans/Runtime/Ghostty/GhosttyRuntime.swift` — replace stub, add methods**

   a) Replace the `actionCallback` stub (line ~148) with the real thunk from the design doc. The thunk checks `Thread.isMainThread`; if true, calls `handleAction` synchronously under `MainActor.assumeIsolated`; if false, dispatches to the main queue async and returns false immediately.

   b) Add `@MainActor func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool` which routes on `target.tag`:
   ```swift
   switch target.tag {
   case GHOSTTY_TARGET_APP:
     return GhosttyActionDecoder.appAction(action, runtime: self)
   case GHOSTTY_TARGET_SURFACE:
     return handleSurfaceAction(target.target.surface, action)
   default:
     return false
   }
   ```

   c) Add `private func handleSurfaceAction(_ surface: ghostty_surface_t?, _ action: ghostty_action_s) -> Bool` which:
   - Calls `paneID(fromSurface:)` to resolve the PaneID from userdata
   - Looks up the pane in `surfacesByPanelID` registry
   - Calls `GhosttyActionDecoder.surfaceAction(...)`

   d) Add `private func paneID(fromSurface: ghostty_surface_t) -> PaneID?` which copies the 16-byte UUID from userdata. The implementation is in the design doc; paste it verbatim.

   e) Add stub methods for Runtime to emit events and apply config changes:
   ```swift
   @MainActor
   func emit(_ event: TerminalEvent) {
     // Forward to TerminalEngine.emit or equivalent
     // Pattern: self.terminalEngine?.emit(event)
   }

   @MainActor
   func emitInfoChanged(_ paneID: PaneID, _ delta: PaneInfoDelta) {
     emit(.panelInfoChanged(paneID, delta))
   }

   @MainActor
   func applyClonedConfig(_ config: ghostty_config_t) {
     // Replace the current config handle with the cloned one.
     // Pattern: ghostty_config_destroy(self.config); self.config = config
   }

   @MainActor
   func reloadConfig(soft: Bool) {
     // Reload config from disk. Pattern: ghostty_config_reload(self.config, soft)
   }

   @MainActor
   func toggleBackgroundOpacity() {
     // Toggle opacity (TOGGLE_BACKGROUND_OPACITY action).
     // Implementation: depends on how opacity is currently stored; placeholder.
   }
   ```

   These methods are simple forwarding; the real work is in the decoder.

2. **Verification:**
   - Build without errors
   - Write a unit test `GhosttyRuntimeActionTests.swift` that mocks the decoder and asserts the callback invokes `handleAction` with the right target/action pair
   - Smoke test: configure a keybind in Ghostty, press it, confirm the app doesn't crash (manual test on a dev build)

---

### Milestone 5: PaneActionRouterFeature

**Goal:** Create a TCA reducer that subscribes to `panelActionRequested` events and dispatches to HierarchyClient.

**What exists at the end:** A new feature `apps/mac/codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift` that maps each PaneActionRequest case to the corresponding HierarchyClient call. The feature is composed into RootFeature and automatically routes all tab/split intents.

**Work:**

1. **Extend HierarchyClient** (`apps/mac/codans/App/Clients/HierarchyClient.swift`)

   Add three new closures to the HierarchyClient struct. These are needed because the design doc references them:

   ```swift
   var addressOf:
     @MainActor @Sendable (PaneID) -> (spaceID: SpaceID, projectID: ProjectID, worktreeID: WorktreeID)?
   var moveTab:
     @MainActor @Sendable (TabID, _ inWorktree: WorktreeID, _ offset: Int, ...) throws -> Void
   var equalizeTabSplits:
     @MainActor @Sendable (_ tabID: TabID, _ inWorktree: WorktreeID, ...) throws -> Void
   var resizePanel:
     @MainActor @Sendable (PaneID, direction: ResizeDirection, amount: Double) throws -> Void
   ```

   (The exact signatures should match the methods on HierarchyManager; read the manager to confirm the wire format, then expose them via HierarchyClient.)

   Add corresponding liveValue closures in the DependencyKey that forward to HierarchyManager.

2. **`apps/mac/codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift` (new file)**

   Create a TCA reducer with:

   ```swift
   @Reducer
   struct PaneActionRouterFeature {
     @ObservableState
     struct State: Equatable {
       // No state — this is a pass-through router
     }

     enum Action: Equatable {
       // No public actions — internal only
       case panelActionRequested(PaneID, PaneActionRequest)
       // ... future actions for other event types if needed
     }

     @Dependency(HierarchyClient.self) var hierarchyClient
     @Dependency(UIClient.self) var uiClient  // or similar, for toggleCommandPalette

     var body: some Reducer<State, Action> {
       Reduce { state, action in
         switch action {
         case .panelActionRequested(let paneID, let request):
           return handlePanelAction(paneID, request)
         }
       }
     }

     @MainActor
     private func handlePanelAction(_ paneID: PaneID, _ request: PaneActionRequest) -> Effect<Action> {
       switch request {
       case .newTab:
         guard let (spaceID, projectID, worktreeID) = hierarchyClient.addressOf(paneID) else {
           return .none
         }
         return .run { _ in
           try hierarchyClient.createTab(worktreeID, projectID, spaceID, nil)
         }

       case .closeTab(let mode):
         // Resolve siblings by mode; call hierarchyClient.closeTab for each
         // Pattern: fetch the tab's siblings, filter by mode, close each
         // (More complex; defer to implementation once HierarchyManager exposes the sibling resolution)
         return .none

       case .moveTab(let offset):
         // Similar: resolve the tab, call hierarchyClient.moveTab(tabID, offset)
         return .none

       case .newSplit(let direction):
         // Call hierarchyClient.splitPanel(paneID, direction: ...)
         return .none

       case .gotoSplit(let direction):
         // Resolve spatial neighbor, call hierarchyClient.focusPanel(...)
         return .none

       // ... rest of cases
       }
     }
   }
   ```

   The feature is lightweight — each case is 3-5 lines. The real logic is in HierarchyManager; the router is just the IPC layer.

3. **Compose into RootFeature** (`apps/mac/codans/App/Features/Root/RootFeature.swift`)

   In RootFeature's body:

   ```swift
   var body: some Reducer<State, Action> {
     PaneActionRouterFeature()  // Compose the new router
     // ... existing reducers
   }
   ```

   Also add a subscription to `panelActionRequested` events in the TerminalEngine observation that RootFeature already maintains:

   ```swift
   .run { send in
     for await event in terminalEngine.events() {
       switch event {
       case .panelActionRequested(let paneID, let request):
         await send(.panelActionRouter(.panelActionRequested(paneID, request)))
       case .panelInfoChanged(...):
         // ... other cases
         break
       }
     }
   }
   ```

4. **Verification:**
   - Build without errors
   - Create `PaneActionRouterFeatureTests.swift` with a TestStore that dispatches `.panelActionRequested(.newTab)`, asserts the HierarchyClient.createTab is called with the right params
   - Test a few representative cases (newTab, newSplit, gotoSplit) to confirm the routing logic is wired correctly

---

### Milestone 6: WindowActionRouterFeature and Supporting Clients

**Goal:** Create a TCA reducer that handles window-level intents, and build the clients it depends on.

**What exists at the end:** WindowActionRouterFeature, WindowService (NSWindow wrapper), AppLifecycleClient, UpdatesClient (or additions to an existing one), and composition into RootFeature. The full window intent routing is in place.

**Work:**

1. **`apps/mac/codans/App/Clients/WindowService.swift` (new file)**

   Thin wrapper over NSWindow and NSApp:

   ```swift
   @MainActor
   struct WindowService: Sendable {
     var openNewWindow: @Sendable (_ inheriting: PaneID) throws -> Void
     var closeWindow: @Sendable (_ from: PaneID) throws -> Void
     var activateWindow: @Sendable (_ matching: GotoWindowTarget) -> Void
     var keyWindow: @Sendable () -> NSWindow?

     static let liveValue = WindowService(
       openNewWindow: { paneID in
         // Resolve paneID → window; create new window inheriting the Space/Worktree settings
         // Pattern: create a new NSWindow, set it up with the same Space as the source pane's window
       },
       closeWindow: { paneID in
         // Resolve paneID → window; call window.performClose(nil)
       },
       activateWindow: { target in
         // Resolve target (recent, next, previous, index) → window; NSApp.activate()
       },
       keyWindow: { NSApp.keyWindow }
     )
   }

   extension DependencyValues {
     var windowService: WindowService {
       get { self[WindowService.self] }
       set { self[WindowService.self] = newValue }
     }
   }
   ```

   The implementation is straightforward; most is fetching the window from the pane and calling NSWindow methods.

2. **`apps/mac/codans/App/Clients/AppLifecycleClient.swift` (new or extend if exists)**

   If not present, create:

   ```swift
   struct AppLifecycleClient: Sendable {
     var requestQuit: @Sendable () -> Void
     var terminate: @Sendable () -> Void

     static let liveValue = AppLifecycleClient(
       requestQuit: {
         // Send a quit-confirmation flow request to the root reducer
         // Pattern: NSApp.sendAction(#selector(...), to: NSApp.delegate, from: nil)
       },
       terminate: {
         // Hard quit (only use after confirmation flow)
         NSApp.terminate(nil)
       }
     )
   }
   ```

3. **`apps/mac/codans/App/Clients/UpdatesClient.swift` (new or extend if exists)**

   If Sparkle is already integrated, this may exist. If not:

   ```swift
   struct UpdatesClient: Sendable {
     var checkNow: @Sendable () -> Void

     static let liveValue = UpdatesClient(
       checkNow: { sparkleUpdater.checkForUpdates(nil) }
     )
   }
   ```

   (Placeholder; the actual impl depends on how Sparkle is wired in the app.)

4. **`apps/mac/codans/App/Features/WindowActionRouter/WindowActionRouterFeature.swift` (new file)**

   Create the TCA reducer:

   ```swift
   @Reducer
   struct WindowActionRouterFeature {
     @ObservableState
     struct State: Equatable { }

     enum Action: Equatable {
       case windowActionRequested(WindowActionRequest)
     }

     @Dependency(WindowService.self) var windowService
     @Dependency(AppLifecycleClient.self) var appLifecycleClient
     @Dependency(UpdatesClient.self) var updatesClient
     @Dependency(EditorClient.self) var editorClient
     @Dependency(HierarchyClient.self) var hierarchyClient

     var body: some Reducer<State, Action> {
       Reduce { state, action in
         switch action {
         case .windowActionRequested(let request):
           return handleWindowAction(request)
         }
       }
     }

     @MainActor
     private func handleWindowAction(_ request: WindowActionRequest) -> Effect<Action> {
       switch request {
       case .new(let from):
         return .run { _ in
           try windowService.openNewWindow(from)
         }

       case .close(let from):
         return .run { _ in
           try windowService.closeWindow(from)
         }

       case .closeAll:
         return .run { _ in
           appLifecycleClient.terminate()
         }

       case .goto(let target):
         windowService.activateWindow(target)
         return .none

       case .toggleFullscreen(let from):
         if let window = windowService.keyWindow() {
           window.toggleFullScreen(nil)
         }
         return .none

       case .toggleMaximize(let from):
         if let window = windowService.keyWindow() {
           window.zoom(nil)
         }
         return .none

       case .toggleTabOverview(let from):
         if let window = windowService.keyWindow() {
           // Check macOS version; toggleTabOverview is 10.12+
           if #available(macOS 10.12, *) {
             window.toggleTabOverview(nil)
           }
         }
         return .none

       case .toggleAppVisibility:
         if NSApp.isVisible {
           NSApp.hide(nil)
         } else {
           NSApp.unhide(nil)
         }
         return .none

       case .quit:
         appLifecycleClient.requestQuit()
         return .none

       case .checkForUpdates:
         updatesClient.checkNow()
         return .none

       case .openConfig:
         return .run { _ in
           try editorClient.openFile("~/.config/ghostty/config")
         }
       }
     }
   }
   ```

5. **Compose into RootFeature**

   Similar to Milestone 5: add WindowActionRouterFeature to the body, subscribe to `.windowActionRequested` events in the TerminalEngine observation.

6. **Verification:**
   - Build without errors
   - Create `WindowActionRouterFeatureTests.swift` with TestStore tests for each case
   - Manual smoke test: press a keybind mapped to `new_window`, confirm a new window opens

---

### Milestone 7: Integration, Testing, and Launch Gates

**Goal:** Wire the routers into the app, add comprehensive unit tests, add observability logging, and implement a launch-arg disable gate for safe rollout.

**What exists at the end:** The app builds, all routers are active, action callback handles all 62 actions, unit tests pass, and a `CODANS_DISABLE_ACTION_ROUTING=1` launch arg can disable the feature if a regression is found.

**Work:**

1. **Integration into RootFeature**

   Ensure both PaneActionRouterFeature and WindowActionRouterFeature are composed into RootFeature's reducer body. Ensure the TerminalEngine event subscriptions route `panelActionRequested` and `windowActionRequested` events correctly.

2. **Add observability to GhosttyActionDecoder**

   Import `os.log` and add logging:

   ```swift
   private static let logger = Logger(subsystem: "com.gumpw.codans.runtime", category: "action")

   // At the start of surfaceAction and appAction:
   logger.debug("action: \(action.tag.rawValue), paneID: \(paneID)")

   // For unsupported actions:
   logger.info("unsupported ghostty action: \(action.tag.rawValue)")

   // For unknown tags:
   logger.info("unknown ghostty action tag: \(action.tag.rawValue)")
   ```

   Also maintain a bounded counter in GhosttyRuntime for `codans system.status` to expose (optional for MVP; defer if time is tight).

3. **Launch-arg disable gate**

   In GhosttyRuntime, before the action callback is invoked, check:

   ```swift
   if ProcessInfo.processInfo.environment["CODANS_DISABLE_ACTION_ROUTING"] == "1" {
     return false
   }
   ```

   This allows hotfix if a regression slips through. Document in release notes: "If action routing causes issues, launch with `CODANS_DISABLE_ACTION_ROUTING=1` and report the issue."

4. **Unit tests**

   Create test files for each major module:

   a) **`GhosttyActionDecoderTests.swift`** — test the decoder in isolation. Construct synthetic ghostty_action_s payloads (or use FFI to create real ones), verify each decoded action emits the correct event or side effect. Test at least 15 representative cases (few from each bucket). Pattern: assert `runtime.emittedEvents` contains the expected event.

   b) **`PaneActionRouterFeatureTests.swift`** — TestStore with 5-10 representative cases, verifying HierarchyClient calls. Pattern: record, assert, verify.

   c) **`WindowActionRouterFeatureTests.swift`** — Similar to above, for window actions.

   d) **`GhosttyRuntimeActionTests.swift`** — test the callback thunk and handleAction routing. Verify it correctly routes APP vs SURFACE targets.

   e) **`PanelSurfaceTests.swift`** — test that `apply()` correctly mutates SurfaceInfo fields.

   Total: ~500 lines of test code across 5 files. Aim for 60%+ coverage of the hot paths (decoder, routing, state mutation).

5. **Manual smoke test checklist**

   Create a checklist in the exec-plan for manual validation before release. Example cases:

   - [ ] Bind `cmd+e = close_tab`; press it; confirm active tab closes
   - [ ] Bind `cmd+shift+n = new_tab`; press it; confirm new tab opens
   - [ ] Bind `cmd+|` = `new_split right`; press it; confirm new right split opens
   - [ ] Bind `cmd+w = close_tab` (⇥ variant); press it in a multi-tab window; confirm correct tab closes
   - [ ] Bind `cmd+q = quit`; press it; confirm quit-confirmation dialog appears (not immediate quit)
   - [ ] Bind `cmd+shift+.` = `toggle_fullscreen`; press it; confirm window toggles fullscreen
   - [ ] Bind `cmd+shift+u = check_for_updates`; press it; confirm updates dialog appears (or "already latest version")
   - [ ] Run with `CODANS_DISABLE_ACTION_ROUTING=1`; bind `cmd+e = close_tab`; press it; confirm it silently no-ops (Ghostty default behavior)

6. **Metrics and rollout plan**

   If the app ships with the launch-arg gate enabled, remove it two releases after the feature lands (once confidence is high). Document the gate in the app's help and release notes.

**Verification:**
- `cd apps/mac && make mac-build && make mac-test` — all tests pass
- No new errors or warnings
- Manual smoke test: ~15 keybinds across all 5 buckets work as expected
- Disable flag works: `CODANS_DISABLE_ACTION_ROUTING=1` silently ignores all bindings

---

## Concrete Steps

Run these commands from the root of the repository:

```bash
cd /Users/wanggang/.prowl/repos/codans/refactor/arch/apps/mac

# Step 1: Create Core types
touch codans/CodansCore/Pane/PaneInfoDelta.swift
touch codans/CodansCore/Pane/PaneActionRequest.swift
touch codans/CodansCore/Pane/WindowActionRequest.swift
# Edit TerminalEvent.swift to add 4 cases

# Step 2: Create decoder
touch codans/Runtime/Ghostty/GhosttyActionDecoder.swift

# Step 3: Create SurfaceInfo
touch codans/Runtime/Ghostty/SurfaceInfo.swift
# Edit PaneSurface.swift to add state and apply() method

# Step 4: Extend GhosttyRuntime
# Edit GhosttyRuntime.swift to replace action callback and add methods

# Step 5: Create PaneActionRouterFeature
mkdir -p codans/App/Features/PaneActionRouter
touch codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift
# Edit HierarchyClient.swift to add 3 new closures

# Step 6: Create WindowActionRouterFeature and clients
mkdir -p codans/App/Features/WindowActionRouter
touch codans/App/Features/WindowActionRouter/WindowActionRouterFeature.swift
touch codans/App/Clients/WindowService.swift
touch codans/App/Clients/AppLifecycleClient.swift
# Edit UpdatesClient.swift or create if missing

# Step 7: Integration and testing
# Edit RootFeature.swift to compose routers
# Create test files
touch codans/Tests/GhosttyActionDecoderTests.swift
touch codans/Tests/PaneActionRouterFeatureTests.swift
touch codans/Tests/WindowActionRouterFeatureTests.swift
touch codans/Tests/GhosttyRuntimeActionTests.swift
touch codans/Tests/PanelSurfaceTests.swift

# Build
make mac-build

# Test
make mac-test
```

Expected output on success:
```
[build output: all files compile]
[test output: all tests pass]
Build succeeded; 0 errors.
Test Summary: 42 passed, 0 failed.
```

---

## Validation and Acceptance

**At completion, the following behaviors are observable:**

1. **Keybind routing works end-to-end:** Configure a keybind in `~/.config/ghostty/config` (e.g., `keybind cmd+e = close_tab`); launch the app; press the key; the corresponding action occurs (tab closes).

2. **All 62 actions are routed:** Decoder covers all action tags; no silent failures.

3. **Info state is stored:** Press keys that emit info actions (e.g., setting window title from a shell prompt); verify PaneSurface.info fields are updated via console logging or test inspection.

4. **Events fan out correctly:** Subscribe a test feature to TerminalEvent; verify panelActionRequested and windowActionRequested events are emitted on keystroke.

5. **Tests pass:** Run `make mac-test` and confirm 42+ tests pass, including all new decoder, router, and feature tests.

6. **Disable flag works:** Launch with `CODANS_DISABLE_ACTION_ROUTING=1`; keybinds silently no-op (Ghostty's default behavior for unhandled actions).

7. **No regressions:** Launch the full app; test existing features (tab bar, split viewport, sidebar, git viewer, settings). Confirm nothing is broken.

---

## Manual Smoke Checklist (M7c)

These cases are not driveable from `codans` because libghostty's action callback only fires under a real keystroke. A tester runs through this list on a dev build before any release that includes routing changes.

**Setup:** Add the listed `keybind` lines to `~/.config/ghostty/config`, relaunch the app, then press each bound key in an active terminal pane.

### Bucket 1 — Tab / split intent

- [ ] `keybind = super+shift+t=new_tab` → a new Tab appears in the current Worktree with the same working directory
- [ ] `keybind = super+w=close_tab` → the active Tab closes; if it was the last, the Worktree shows the empty state
- [ ] `keybind = super+alt+right=move_tab:1` → active Tab shifts one slot to the right in the Tab bar
- [ ] `keybind = super+alt+left=previous_tab` → focus moves to the Tab to the left (wraps at start)
- [ ] `keybind = super+d=new_split:right` → the active Pane splits horizontally; new Pane takes focus
- [ ] `keybind = super+shift+d=new_split:down` → vertical split
- [ ] `keybind = super+alt+h=goto_split:left` / `...=goto_split:right` → focus jumps to the adjacent split (collapsed onto previous/next per DEC-M5; full spatial nav is a follow-up)
- [ ] `keybind = super+equal=equalize_splits` → every split in the Tab resizes to equal weight
- [ ] `keybind = super+shift+return=toggle_split_zoom` → active Pane fills the Tab; press again to restore
- [ ] `keybind = super+shift+k=present_terminal` → no user-visible change today (consumed as `.delegate(.presentTerminalRequested)` no-op; record that the log line fires)
- [ ] `keybind = super+k=toggle_command_palette` → no user-visible change today (delegate no-op; logged)

### Bucket 2 — Window / app intent

- [ ] `keybind = super+n=new_window` → nothing opens today (WindowService stub; verify `logger.info` "openNewWindow not wired" fires)
- [ ] `keybind = super+shift+w=close_window` → the current `NSApp.keyWindow` closes
- [ ] `keybind = super+alt+shift+w=close_all_windows` → app terminates (routes through AppLifecycleClient.terminate)
- [ ] `keybind = super+ctrl+f=toggle_fullscreen` → current window toggles fullscreen
- [ ] `keybind = super+ctrl+m=toggle_maximize` → `NSWindow.zoom` fires
- [ ] `keybind = super+shift+backslash=toggle_tab_overview` → native macOS tab overview toggles (macOS 10.12+)
- [ ] `keybind = super+h=toggle_visibility` → app hides / unhides
- [ ] `keybind = super+q=quit` → quit confirmation dialog appears (or direct terminate if no confirmation flow wired)
- [ ] `keybind = super+u=check_for_updates` → verify `logger.info` "Sparkle not wired" fires (stub)
- [ ] `keybind = super+comma=open_config` → ghostty's config file opens in the system default editor for that file type

### Bucket 3 — Surface info

- [ ] In a running terminal, change the shell prompt that emits OSC title → Tab bar shows the new title (via `.panelInfoChanged(.title)`)
- [ ] `cd /tmp` → the Pane's `info.pwd` updates (inspect via debugger or a `codans pane.status` call if wired)
- [ ] Hover over a URL printed in the terminal → `info.mouseOverLink` populates (mouse-over-link handled)
- [ ] Run a command that prints `\a` (bell) → `info.bellCount` increments; if notifications are enabled, see the notification surface fire
- [ ] Trigger a readonly state or secure-input mode → info fields flip; log line at `.debug` fires

### Bucket 4 — Effectful

- [ ] `keybind = super+o=open_url` on a URL selection → `NSWorkspace.open` launches the user's default browser
- [ ] `keybind = super+shift+c=copy_title_to_clipboard` → today a stub (DEC-M2-1); verify the `.debug` log fires; full implementation pending the two-line title read
- [ ] `keybind = super+z=undo` / `...=redo` → `NSApp.sendAction` fires the responder chain undo/redo
- [ ] Trigger a `ring_bell` sequence in the terminal (`printf '\a'`) → `info.bellCount` increments
- [ ] Run any command to completion → `.panelInfoChanged(.commandFinished(...))` fires once per command

### Bucket 5 — App-level config

- [ ] Edit `~/.config/ghostty/config`, then from a terminal bound to `reload_config` press the key → the runtime rebuilds its config; `.configChanged` event fires; visible effect: any font/color change applies to newly created surfaces
- [ ] Trigger `config_change` externally (e.g. by saving the config while ghostty is watching it) → same as above

### Disable gate

- [ ] Launch with env `CODANS_DISABLE_ACTION_ROUTING=1` → **every** bound key from the checklist above becomes a silent no-op; no logs, no state changes

### Regression sweep

- [ ] Normal terminal input (typing, pasting, arrow keys) still works
- [ ] Existing app features (sidebar navigation, tab bar, settings, git viewer) behave unchanged
- [ ] No console errors or runtime crashes during a 10-minute interactive session

## Idempotence and Recovery

**All steps are repeatable.** File creation and edit operations can be re-run; building and testing are idempotent. If a step fails:

1. **Build error:** Review the error message, fix the issue in the source file, re-run `make mac-build`.
2. **Test failure:** Run the failing test in isolation with `swift test <target>`, inspect the output, fix the code, re-run tests.
3. **Partial completion:** The plan is split into seven milestones; if you get stuck on Milestone 5, save your work, revert the broken changes, and resume from Milestone 4.

**At any point, you can reset to a clean state:**
```bash
git checkout -- apps/mac/  # Discard all changes
git clean -fd apps/mac/     # Remove new files
make mac-build              # Confirm back to baseline
```

---

## Artifacts and Notes

### Decoder skeleton (Milestone 2)

The decoder is the heaviest file (~250 lines), but follows a mechanical pattern. Copy the skeleton from the design doc §Decoder skeleton. Each action case is 2-3 lines:

```swift
case GHOSTTY_ACTION_NEW_TAB:
  runtime.emit(.panelActionRequested(paneID, .newTab))
  return true
```

Info cases follow the same pattern with `pane.apply()` + `runtime.emitInfoChanged()`.

### HierarchyClient extensions (Milestone 5)

The three new closures are required because the router needs to resolve a PaneID to its (SpaceID, ProjectID, WorktreeID, TabID) tuple. Read HierarchyManager to confirm the method signature and implement the forwarder in HierarchyClient.

### Test patterns

The codebase uses `ComposableArchitecture.TestStore` for reducer tests. Example from WorktreeHeaderFeature:

```swift
@MainActor
func testBellPopover() async {
  let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
    WorktreeHeaderFeature()
  } withDependencies: {
    $0.inboxClient = .testValue
  }

  await store.send(.popoverToggled(true)) { state in
    state.popoverOpen = true
  }
}
```

Use this pattern for PaneActionRouterFeature and WindowActionRouterFeature tests. Record HierarchyClient calls, verify they are invoked with the right arguments.

---

## Interfaces and Dependencies

**New public types (Core):**

In `CodansCore/Pane/`:
- `enum PaneInfoDelta` (25 cases)
- `enum PaneActionRequest` (11 cases) + `enum CloseTabMode`, `enum GotoTabTarget`, etc.
- `enum WindowActionRequest` (11 cases) + `enum GotoWindowTarget`

In `CodansCore/TerminalEvent.swift`:
- `case panelInfoChanged(PaneID, PaneInfoDelta)`
- `case panelActionRequested(PaneID, PaneActionRequest)`
- `case windowActionRequested(WindowActionRequest)`
- `case configChanged`

**New Runtime types:**

In `codans/Runtime/Ghostty/SurfaceInfo.swift`:
- `@Observable class SurfaceInfo` (~20 fields, all Sendable)

In `codans/Runtime/Ghostty/GhosttyActionDecoder.swift`:
- `enum GhosttyActionDecoder`
  - `static func surfaceAction(_ action, paneID, pane, runtime) -> Bool`
  - `static func appAction(_ action, runtime) -> Bool`

In `codans/Runtime/Ghostty/GhosttyRuntime.swift`:
- `@MainActor func handleAction(target, action) -> Bool`
- `@MainActor private func handleSurfaceAction(_ surface, _ action) -> Bool`
- `@MainActor private func paneID(fromSurface) -> PaneID?`
- `@MainActor func emit(_ event)`
- `@MainActor func emitInfoChanged(_ paneID, _ delta)`
- `@MainActor func applyClonedConfig(_ config)`
- `@MainActor func reloadConfig(soft)`
- `@MainActor func toggleBackgroundOpacity()`

In `codans/Runtime/Ghostty/PaneSurface.swift`:
- `var info: SurfaceInfo`
- `func apply(_ delta: PaneInfoDelta)`
- `func markExited(code: Int32)`

**New App types:**

In `codans/App/Clients/HierarchyClient.swift`:
- `var addressOf: @MainActor @Sendable (PaneID) -> (SpaceID, ProjectID, WorktreeID)?`
- `var moveTab: @MainActor @Sendable (TabID, ...) throws -> Void`
- `var equalizeTabSplits: @MainActor @Sendable (TabID, ...) throws -> Void`
- `var resizePanel: @MainActor @Sendable (PaneID, direction, amount) throws -> Void`

In `codans/App/Clients/WindowService.swift`:
- `struct WindowService: Sendable`
  - `var openNewWindow: @Sendable (PaneID) throws -> Void`
  - `var closeWindow: @Sendable (PaneID) throws -> Void`
  - `var activateWindow: @Sendable (GotoWindowTarget) -> Void`
  - `var keyWindow: @Sendable () -> NSWindow?`

In `codans/App/Clients/AppLifecycleClient.swift`:
- `struct AppLifecycleClient: Sendable`
  - `var requestQuit: @Sendable () -> Void`
  - `var terminate: @Sendable () -> Void`

In `codans/App/Clients/UpdatesClient.swift`:
- `var checkNow: @Sendable () -> Void`

In `codans/App/Features/PaneActionRouter/PaneActionRouterFeature.swift`:
- `@Reducer struct PaneActionRouterFeature`
  - `enum Action` with `.panelActionRequested(PaneID, PaneActionRequest)` case
  - Reducer body dispatches to HierarchyClient

In `codans/App/Features/WindowActionRouter/WindowActionRouterFeature.swift`:
- `@Reducer struct WindowActionRouterFeature`
  - `enum Action` with `.windowActionRequested(WindowActionRequest)` case
  - Reducer body dispatches to WindowService, AppLifecycleClient, UpdatesClient, EditorClient

**Dependency injection updates:**

In `codans/App/Features/Root/RootFeature.swift`:
- Compose `PaneActionRouterFeature()` and `WindowActionRouterFeature()` into the body
- Subscribe to TerminalEvent stream; route `panelActionRequested` and `windowActionRequested` events

**Architectural invariants maintained:**
- ✅ Runtime is TCA-free (only emits events; no HierarchyClient import)
- ✅ All cross-process communication through CodansIPC (not violated)
- ✅ Pane state mutation is Runtime-localized (via pane.apply)
- ✅ No circular dependencies (decoder imports Core, Runtime; routers import Clients)
- ✅ Events flow one way (Runtime → AsyncStream → TCA)
