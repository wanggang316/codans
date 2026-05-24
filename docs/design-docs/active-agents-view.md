# Design Doc: ActiveAgents View

**Status:** Draft
**Author:** Gump (with Claude)
**Date:** 2026-05-22

## Context and Scope

touch-code runs coding agents (Claude Code, Codex CLI, pi, …) as
first-class inhabitants of Panes. In a typical session a user has
2–8 Panes distributed across Worktrees; most are driven by an agent;
the user attends only to whichever one is currently working, has just
finished, or is asking for input. Today the only cross-pane affordances
for that signal are (a) the per-pane OSC 9;4 "busy" strip, (b) the
sidebar / tab-chip busy glyph aggregated from the same source, and
(c) the inbox of past `taskFinished` / `waitingForInput` events. None
of them answers the question "which agents are alive right now and what
is each one doing", which is the question the user actually asks before
deciding where to look next.

This doc designs **ActiveAgents** — an in-app status-bar entry plus
hover popover that lists every Pane currently identified as running a
known agent and shows its derived runtime state. The popover is the
single place a user goes to triage agents across all worktrees.

The system that classifies and surfaces *individual transitions* as
notifications (see [notifications.md](notifications.md)) already exists;
ActiveAgents is a **parallel, independent consumer** of the same raw
signals — `HierarchyManager.runningPanes`, the `TerminalEvent` stream,
and per-surface info from libghostty. It does **not** depend on
`NotificationStore` and is unaffected by mute/notification settings.

## Goals and Non-Goals

**Goals**

- A status-bar entry in `WorktreeHeader` shows a one-line summary of
  all active agents across all worktrees (e.g., "3 agents working",
  "Claude is waiting for input").
- Hovering the entry opens a popover listing one row per agent-bearing
  Pane: agent logo, project + worktree label, derived runtime state
  (with an animated indicator for `loading`), last-event time.
- Clicking a row focuses that Pane, switching project / worktree / tab
  as needed.
- Identification covers **Claude Code**, **Codex** (OpenAI Codex CLI),
  and **pi** (Inflection's pi CLI). All other panes simply do not
  appear in ActiveAgents.
- A new `AgentRegistry` owns the per-Pane runtime state machine,
  driven by `runningPanes`, the `TerminalEvent` stream, and the
  `PaneKeyboardActivityTracker`. Pure runtime state — not persisted.
- Two new optional fields on `Pane` (`agentKind`, `agentSessionID`)
  persist *which* agent a Pane is bound to. Pane identity decisions
  outlast app relaunches; runtime state does not.

**Non-Goals**

- A general-purpose agent FSM with rich transition history — that was
  C6 v1's `AgentStateTracker`, abandoned for being more machinery than
  the inbox needed. We re-use the lesson: ActiveAgents stores the
  minimum derived state per Pane to render the popover, nothing more.
- Detecting arbitrary agents (aider, custom in-house CLIs, future
  tools) in v1. The kind registry is a hand-maintained allowlist —
  new agents are a code change, not a config change. Generalising
  this is a future-work concern.
- A new IPC surface or `tc` command. ActiveAgents is in-app only.
- Re-implementing the notifications inbox UX. The two systems share
  no UI; muted Panes still appear in ActiveAgents.
- Cross-window or multi-app behaviour. ActiveAgents is anchored to
  the touch-code main window's `WorktreeHeader`.
- Status-bar entry as `NSStatusItem` (macOS menu bar / Dynamic-Island
  style). v1 ships an in-app `WorktreeHeader` entry; menu-bar variant
  is future work.
- Persisting derived runtime state. Only the *binding* (agentKind,
  agentSessionID) survives relaunch; loading / waiting / finished
  are recomputed from the live event stream each launch.

## Design

### Overview

Three components, all in-process, with a strict one-way dependency:

```
   identification           runtime state           UI
 ┌──────────────────┐    ┌─────────────────┐   ┌────────────────────┐
 │  AgentBinder     │───▶│  AgentRegistry  │──▶│ ActiveAgentsView   │
 │  (writes Pane    │    │  (derives state │   │ + status-bar entry │
 │   fields)        │    │   from events)  │   │  in WorktreeHeader │
 └──────────────────┘    └─────────────────┘   └────────────────────┘
        ▲                       ▲                       │
        │                       │              click ──▶│
        │                       │              focusPane via
        SurfaceInfo /     runningPanes,        HierarchyClient
        TerminalEvent     TerminalEvent,
                          keyboard tracker
```

**Why this shape.** Two design tensions drive the split.

The first is **identification vs. state**: "is this Pane an agent at
all?" is a slow-changing, persistable fact that needs to outlast app
relaunches (so the user's logo-bearing rows don't all disappear after
a restart). "What is this agent doing right now?" is a fast-changing,
disposable derivation. Mixing them produced the heavyweight FSM of
the deprecated C6 v1 design; separating them lets each layer be small.

The second is **independence from notifications**. The notifications
detector and ActiveAgents share three input streams but answer
different questions. Forcing one to consume the other's outputs
(e.g., "ActiveAgents reads InboxStore for the `finished` state") would
couple mute policy, dedup windows, and rule grammar into a layer that
should not care about them. Instead, both subscribe to raw signals;
their outputs never cross.

A third, lighter pressure: the `Pane.labels` Set<String> already
carries `notifications:muted`, which is intentionally a string because
the notifications layer treats labels as orthogonal user-facing tags.
Re-using it for `agent:claude` would couple two unrelated subsystems
through the same untyped set. We pay a small migration cost for
explicit `Pane.agentKind` / `Pane.agentSessionID` fields instead.

### System Context Diagram

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │                            touch-code app                                │
 │                                                                          │
 │  Runtime/C1 ──▶ TerminalEngine ── AsyncStream<TerminalEvent> ─┐          │
 │                                                                │          │
 │  GhosttyRuntime ── @Observable SurfaceInfo (per-PaneSurface) ──┤          │
 │                                                                │          │
 │  PaneKeyboardActivityTracker ──────────────────────────────────┤          │
 │                                                                ▼          │
 │  HierarchyManager.runningPanes ──▶  ┌──────────────────────────────┐     │
 │                                     │ AgentBinder (Runtime layer)  │     │
 │                                     │   identifies agent kind +    │     │
 │                                     │   writes Pane.agentKind /    │     │
 │                                     │   Pane.agentSessionID via    │     │
 │                                     │   HierarchyClient            │     │
 │                                     └──────────────┬───────────────┘     │
 │                                                    │                     │
 │                                                    ▼                     │
 │  ┌────────────────────────────────────────────────────────────────────┐  │
 │  │ AgentRegistry (App/Features/ActiveAgents/)                         │  │
 │  │   Observable [PaneID → AgentEntry]                                 │  │
 │  │   AgentEntry = (kind, sessionID, derivedState, lastTransitionAt)   │  │
 │  │   subscribes: runningPanes diff, TerminalEvent stream,             │  │
 │  │               PaneKeyboardActivityTracker                          │  │
 │  └─────────────────────────┬──────────────────────────────────────────┘  │
 │                            │                                              │
 │             ┌──────────────┴───────────────┐                              │
 │             ▼                              ▼                              │
 │   ActiveAgentsBadgeView           ActiveAgentsPopoverView                 │
 │   (text + icon in                 (list rows, hover bridge)               │
 │    WorktreeHeader)                 click ──▶ HierarchyClient.focusPane    │
 └──────────────────────────────────────────────────────────────────────────┘
```

### Data Storage

The catalog gains two optional fields on `Pane` (in
`TouchCodeCore/Pane.swift`). Both are persisted; both default to nil.

```swift
public struct Pane: Equatable, Sendable, Identifiable {
    // … existing fields …

    /// Identifies the agent tool the user is running in this pane.
    /// nil = pane has never been identified as an agent (or has been
    /// explicitly cleared). Once bound, the value sticks across pane
    /// lifetime and app relaunches until AgentBinder observes a
    /// rebind condition (shell returns to prompt + new agent appears,
    /// or pane is closed).
    public var agentKind: AgentKind?

    /// The agent's own session identifier when one can be captured
    /// (e.g., Claude Code prints a session UUID in its startup banner).
    /// v1 declares the field but does not populate it — wired in a
    /// follow-up so banner parsing can land independently.
    public var agentSessionID: String?
}

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case pi
}
```

**Codable forward compatibility.** Both fields are optional and emitted
only when non-nil — old `catalog.json` files decode unchanged; downgrade
to a prior touch-code build silently drops the fields. No migration
script needed.

**No new persisted runtime state.** The `AgentRegistry`'s derived state
(loading / waitingForInput / finished / idle) lives entirely in memory
and is rebuilt from the event stream on each launch. After relaunch a
Pane shows `idle` until the next signal arrives — acceptable because
relaunch already drops every other in-memory runtime state (busy bit,
last-focused-pane-by-tab, etc.).

### Agent Identification

This is the trickiest sub-design because libghostty does **not**
expose the surface's foreground process via `SurfaceInfo`. We rely
on three signal sources, in fallback order:

1. **`Pane.initialCommand`** — the command tc spawned the pane with.
   Already on the model but currently not persisted across relaunch
   (see `Pane.swift` comment: it's a one-shot replay input). Matched
   case-insensitively against `AgentKind.commandPatterns` (e.g.,
   `claude`, `claude-code`, `codex`, `pi`).
   - Covers panes created by `tc tab new "claude"` and the "New Tab
     with command" UI affordance — high precision, immediate.

2. **`SurfaceInfo.title`** — terminal title updates. All three target
   agents set the window title to a recognisable prefix at startup
   (e.g., Claude Code uses `Claude Code`, Codex uses `Codex CLI`,
   pi uses `pi`). Matched against `AgentKind.titlePatterns`.
   - Covers panes that came up as a plain shell and had the user
     subsequently run an agent. Also covers relaunches (since
     `initialCommand` is gone but the title is re-emitted by the
     running process).
   - **Trade-off:** title-based matching is heuristic. Pattern strings
     ship as a `Sources/TouchCodeCore/AgentKindPatterns.swift` table
     so test cases can exercise them; future agents that change their
     title prefix break detection until the table updates.

3. **OSC 9 banner text** — when an agent sends a desktop notification,
   the title may carry an unambiguous brand string. Used **only** as
   a tie-breaker when neither (1) nor (2) decided.

If none of the three matches, the pane is simply not bound; it does
not appear in ActiveAgents.

**`AgentBinder`** lives in `apps/mac/touch-code/Runtime/AgentBinder.swift`
(Runtime layer, alongside `HierarchyManager`). It subscribes to:
- `SurfaceInfo.title` changes (via `@Observable` change tracking
  through the existing `PaneSurface` observation channel),
- `TerminalEvent.paneInfoChanged` with `.desktopNotification(...)`,
- pane lifecycle (`paneCreated`, `paneExited`, `paneCrashed`).

On any of these, it runs `classify(initialCommand, title, notif)` →
`AgentKind?`. When the result differs from `pane.agentKind`, it
writes via `HierarchyClient.setPaneAgentKind(paneID, kind)`.

**Sticky binding & rebind.** Once `agentKind` is set, the binder
holds it until one of:
- `paneExited` / `paneCrashed` / `paneClosedByTab` → clear field.
- OSC 133 prompt event (shell returned to top-level prompt) AND the
  current title pattern matches a *different* agent kind → rebind.

The OSC 133 hook is the only escape valve from sticky identification
within a live pane; without it, claude-then-codex in the same shell
would never re-identify. Panes that never see OSC 133 (no shell
integration) get sticky-identified once and stay that way for their
lifetime — acceptable for v1.

### Runtime State Derivation

`AgentRegistry` (in `App/Features/ActiveAgents/AgentRegistry.swift`,
`@MainActor @Observable`) holds:

```swift
struct AgentEntry {
    let kind: AgentKind
    let sessionID: String?
    var state: AgentRuntimeState
    var lastTransitionAt: Date
}

enum AgentRuntimeState {
    case waitingForInput
    case loading           // == "working" in product copy
    case finished
    case idle
}

@MainActor @Observable
final class AgentRegistry {
    private(set) var entries: [PaneID: AgentEntry] = [:]
    // Internal per-pane scratch state:
    //   prevPhase: .idle | .loading  (drives finished detection)
    //   pendingFinished: Bool
    //   waitingForInput: Bool
}
```

Inputs and reactions (one place — the only state machine in the
system):

| Signal | Effect |
|---|---|
| `runningPanes` gains pane | `prevPhase = .loading`; clear `pendingFinished` |
| `runningPanes` loses pane | if `prevPhase == .loading`, set `pendingFinished = true`; `prevPhase = .idle` |
| `TerminalEvent.paneIdle` | if `prevPhase == .loading`, set `pendingFinished = true` |
| `paneExited` / `paneCrashed` | set `pendingFinished = true` (terminal state until cleared) |
| OSC 9 / bell classified as `waitingForInput` (`DetectionTranslator.classify`) | set `waitingForInput = true` |
| `PaneKeyboardActivityTracker` records key in pane | clear `waitingForInput`; clear `pendingFinished` |
| `paneOutput` (new bytes) | clear `pendingFinished`; leave `waitingForInput` untouched (agent may be printing the prompt) |
| Pane gains focus (selection chain points at it AND app frontmost) | clear `pendingFinished`; clear `waitingForInput` |
| `agentKind` becomes nil | drop entry from registry |

Final state is a pure function of the scratch fields plus the live
`runningPanes` set:

```
derive(pane) =
    .waitingForInput     if waitingForInput
    .loading             if runningPanes.contains(paneID)
    .finished            if pendingFinished
    .idle                otherwise
```

The derivation matches Gump's stated semantic: `finished` is exactly
"this pane was working and the resulting transition has not been
acknowledged yet". `AgentRegistry` owns the acknowledgement flag
locally — it does not read `NotificationStore.readAt`, keeping the
two subsystems independent.

`DetectionTranslator.classify` is the same pure function the
notifications detector uses for OSC 9 / bell classification —
re-exported from `TouchCodeCore` so both consumers share one
implementation.

### UI

**Status-bar entry** lives in `WorktreeHeader`, between the existing
inbox bell (`StatusBarBellView`) and the worktree label. One
SwiftUI view, `ActiveAgentsBadgeView`, observes the registry and
renders:

- **Empty state** (no entries): hidden entirely.
- **Single agent**: agent's logo + `"<DisplayName> is <verb>"` —
  e.g., `"Claude Code is waiting for input"`.
- **Multiple agents, same state**: small badge + count, e.g.,
  `"3 agents working"`.
- **Mixed states**: condensed form prioritising the highest-priority
  state, e.g., `"2 working · 1 waiting"`.

Verb priority for the headline: `waitingForInput > loading > finished > idle`.
The icon pulses (subtle opacity 0.6 ↔ 1.0 over 1.2 s, prefers-reduced-
motion respected) when any entry is in `loading` or `waitingForInput`.

**Hover popover** uses SwiftUI's `.popover(isPresented:)` with a
`.hovering`-based controller that opens after 250 ms of sustained
hover and closes 150 ms after pointer exit from both the badge and
the popover content (hover bridge — popover stays open while the
pointer is over it).

Popover contents:
- Header: `"Active Agents (<n>)"`
- Sorted list of all `AgentEntry`s, sorted by:
  1. State priority: `waitingForInput > finished > loading > idle`
     (Gump's order — surfaces the rows the user needs to triage
     first; idle drops to bottom).
  2. `lastTransitionAt` descending within the same state bucket.
- Each row:
  - Leading: 16pt agent logo (SF Symbol fallback `brain.head.profile`
    if asset missing).
  - Title line: `<ProjectName> / <WorktreeName>` (truncated middle).
  - Subtitle: state icon + state label + relative time
    (`"working · 12s"` / `"waiting · 4m"` / `"finished · just now"` /
    `"idle · 1h"`).
  - State icon set:
    - `.waitingForInput` → `bell.badge.fill`, amber.
    - `.loading` → rotating `arrow.triangle.2.circlepath`, accent.
    - `.finished` → `checkmark.circle.fill`, green.
    - `.idle` → `circle`, secondary.
  - Click: dispatches a Root action that walks the catalog to the
    pane's `(projectID, worktreeID, tabID, paneID)`, selects each
    level, calls `HierarchyClient.focusPane`, and dismisses the
    popover.
  - Row gains a faint hover background; whole row is the click
    target for Fitts's-law.

**Logo assets** ship in `apps/mac/touch-code/Resources/Assets.xcassets/
AgentLogos/`:
- `claude-code.imageset` — Anthropic Claude wordmark / leaf glyph.
- `codex.imageset` — OpenAI Codex spiral.
- `pi.imageset` — Inflection pi glyph.

Sourced from the agents' official press / brand kits at build-doc
time; both light and dark variants stored. License risk noted in the
Risks section. The fallback SF Symbol covers any future kind we add
without an asset.

### Component Boundaries

| Layer | New module | Responsibilities | Forbidden imports |
|---|---|---|---|
| `TouchCodeCore` | `AgentKind`, `AgentKindPatterns`, `Pane.agentKind/agentSessionID` | Value types, pattern table | Nothing |
| `apps/mac/touch-code/Runtime` | `AgentBinder.swift` | Identify agent kind, write Pane fields via `HierarchyClient` | App features layer |
| `apps/mac/touch-code/App/Features/ActiveAgents` | `AgentRegistry`, `ActiveAgentsBadgeView`, `ActiveAgentsPopoverView`, `ActiveAgentsRowView` | Derived state, UI | Runtime internals; no `NotificationStore` |
| `apps/mac/touch-code/App/Features/WorktreeHeader` | Updated `WorktreeHeaderView` | Hosts `ActiveAgentsBadgeView` | — |

**Dependency direction.** `ActiveAgents → TouchCodeCore`,
`ActiveAgents → HierarchyClient` (read), `ActiveAgents → catalog
read-only`, `ActiveAgents → PaneKeyboardActivityTracker` (read).
ActiveAgents does **not** import `Notifications/*`.

`HierarchyClient` gains exactly two new methods:

```swift
var setPaneAgentKind: @MainActor @Sendable (PaneID, AgentKind?) -> Void
var setPaneAgentSessionID: @MainActor @Sendable (PaneID, String?) -> Void
```

Backed by new `HierarchyManager.setPaneAgentKind` /
`setPaneAgentSessionID` writers that go through the standard
debounced save pipeline.

## Alternatives Considered

**A. Re-use `Pane.labels` with `agent:<kind>` string keys.**
Considered because the mute path already uses `Pane.labels` and a
single `Set<String>` keeps the data model flat. Rejected on the
grounds Gump raised explicitly: string keys are not type-checked at
the field level, encourage drift between writers and readers, and
co-mingle two unrelated subsystems (notifications mute and agent
identification) in one untyped bag. The migration cost of two
optional fields is small; the long-term clarity gain is large.

**B. Revive C6 v1's per-Pane `AgentStateTracker` FSM with persisted
transitions.** Provides richer history (e.g., "this agent went
loading → waiting → loading three times in the last minute") and a
persistable timeline. Rejected because ActiveAgents needs exactly
the most recent state — not a transition log — and adding persistence
back doubles the surface area for a feature whose entire value is "a
list that's always right *now*". The flag-based derivation above is
testable in pure Swift with zero I/O.

**C. Couple `finished` to `InboxEntry.readAt`.** ActiveAgents would
look up "is there an unread `taskFinished` InboxEntry for this pane?"
to decide `finished` vs `idle`. Considered because it would make
ActiveAgents and the notifications inbox feel "in sync" — clearing
the inbox row would also clear the green check in ActiveAgents.
Rejected because (i) it forces a dependency edge from a UI feature
into the notifications storage layer, exactly the kind of coupling
the two-consumers-one-signal-source split avoids; (ii) mute/dedup
policies would then leak into ActiveAgents semantics; (iii) the
local flag with identical clear-triggers (focus, keystroke, new
output) produces the same observable behaviour without the coupling.

**D. macOS `NSStatusItem` (menu bar) instead of in-app
`WorktreeHeader`.** Considered because it best evokes the
"Dynamic-Island"-style affordance Gump described. Rejected for v1
on Gump's call: deferring NSStatusItem keeps work within existing
SwiftUI hosting and reuses the popover anchoring story the inbox
bell already proved. The split between `AgentRegistry` and
`ActiveAgentsBadgeView` is deliberately UI-agnostic so an
NSStatusItem variant is a future swap, not a rebuild.

**E. Live process-name polling via `ps -o comm`.** Would give
ground-truth identification independent of title strings.
Rejected because (i) libghostty does not expose the pty child PID
through `SurfaceInfo` today; getting it would mean a new C-API
binding; (ii) polling every Pane every N seconds is wasteful versus
the event-driven `SurfaceInfo.title` subscription that costs zero
when nothing changes; (iii) when the pty child is `bash`, `ps`
sees `bash` even though the user is "running claude" — we'd be back
to needing process-tree walks.

**F. Auto-include all panes (no identification step), display as
`generic` until proven otherwise.** Considered as the
identification-free minimum. Rejected because the popover would
list every shell, build script, and REPL — drowning the actual
agents. The product value lives in the curation.

## Cross-Cutting Concerns

**Testing.**
- `AgentKindPatterns` is a pure table → exhaustive unit tests in
  `TouchCodeCoreTests` exercise every pattern against fixture
  command lines and titles.
- `AgentRegistry` state derivation is a pure function from
  (scratch state, signal) → new state → derived state. Tests live
  in `touch-codeTests/Features/ActiveAgentsRegistryTests.swift`,
  driven by hand-built signal sequences (no live runtime).
- `AgentBinder` is tested against an in-memory `HierarchyClient`
  spy that records `setPaneAgentKind` calls; tests cover (i)
  initial detection from `initialCommand`, (ii) detection from
  title change after a delay, (iii) rebind on OSC 133 + new title,
  (iv) clear on paneExited.
- UI: snapshot tests on `ActiveAgentsRowView` (each state) and
  `ActiveAgentsBadgeView` (empty / single / multi / mixed).

**Performance.** `AgentRegistry.entries` is keyed by `PaneID`; a
typical session has <20 panes. State derivation per signal is O(1)
hashing + Set lookup. The popover renders a list of at most
~20 rows; SwiftUI's `LazyVStack` is overkill at this scale, plain
`VStack` is fine.

**Observability.** `Logger(subsystem: "com.touch-code.activeagents")`
emits `info` on identification (which signal won), `debug` on each
state transition, `warning` on unbind-by-rebind (helps diagnose
runaway re-identification loops). No counters / metrics in v1.

**Accessibility.**
- Status-bar entry: full `accessibilityLabel` covering current
  headline ("Claude Code is waiting for input"), `accessibilityHint`
  ("Open the active agents popover").
- Popover rows: `accessibilityLabel` combining agent, worktree,
  state, age. State icons carry `accessibilityHidden(true)` since
  the label already encodes the state.
- Pulse animation respects `accessibilityReduceMotion`.

**Migration / rollback.** No schema migration (optional fields).
Disabling ActiveAgents would mean removing the badge view from
`WorktreeHeaderView` and gating registry/binder behind a feature
flag (`Settings.developer.activeAgentsEnabled`, default `true`).
Persisted `agentKind` fields are left in place and ignored if the
feature is disabled — no data loss.

**Settings.** v1 adds no user-facing setting. The popover is always
available; users who don't want it can simply never hover it. A
toggle is easy to add later if user feedback demands it.

## Risks

| Risk | Mitigation |
|---|---|
| Title-based identification breaks when an agent changes its window-title prefix between releases | Pattern table lives in code, not config; updates are a one-line PR. CI fixture for each kind locks the current pattern. |
| Sticky binding misidentifies a pane forever if shell-integration is absent and the user switches agents in the same shell | OSC 133 prompt-end is the rebind trigger; without it, sticky-once is the documented v1 limitation. Future: add a manual "Reset agent identity" item to the pane context menu. |
| Multiple writers race on `Pane.agentKind` (binder + manual reset path) | Both writes go through `HierarchyManager` on `@MainActor`; the existing debounced save pipeline already serialises catalog mutations. |
| Logo assets for Claude / Codex / pi carry brand-mark license constraints | Use the agents' public press / brand kits and the brand glyph only (no wordmark). If a logo's terms are ambiguous, ship a generic glyph for that kind in v1 and revisit before any commercial release. |
| `paneIdle` 30 s threshold marks a still-thinking agent as `finished` when it goes quiet between tool calls | The same trade-off already governs the inbox `taskFinished` event; if it proves wrong in practice, both consumers benefit from raising the threshold once in `DetectionTranslator.idleThreshold`. |
| Popover hover-bridge feels fragile on slow gestures | 250 ms open / 150 ms close numbers are tunable in one place (`ActiveAgentsBadgeView`); revisit after first dogfood pass. Click-toggle is always available as a backup. |
| `AgentRegistry` and `NotificationStore` diverge on what constitutes "the same event" (e.g., one shows finished, the other doesn't) | Documented as expected behaviour — the two systems answer different questions and share only raw signals. Validation: a small test in `touch-codeTests` asserts both systems classify a canned OSC 9 sequence and an OSC 9;4 transition consistently against `DetectionTranslator.classify`. |
