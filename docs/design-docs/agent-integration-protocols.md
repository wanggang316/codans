# Agent integration contracts

## Status and scope

Proposed replacement for the phase-1 abstraction in HAN-167 / PR #211.
The current code extracts 13 parsers but still exposes terminal error signatures
in the generic observation and declares recovery support on the parser. This
proposal changes those contracts; the types and behavior below are not yet
implemented. Review reproduced two final-error classification failures and an
instance-replacement recovery failure, and identified missing input invalidation
on Send Now and CLI paths.

The implementation scope is unified state, terminal observation, instance-bound
recovery, input coordination, and one Agent registry. History-format extraction
is a subsequent independent change. Existing launch and resume behavior must be
preserved during registry consolidation.

## 1. One state model

```swift
enum AgentState: Equatable, Sendable {
  case unknown
  case idle
  case working
  case blocked
  case error(AgentFailure)
}

struct AgentFailure: Equatable, Sendable {
  let reason: Reason
  let message: String
  let providerCode: String?
  let retryAfterSeconds: Int?

  enum Reason: Equatable, Sendable {
    case transient
    case rateLimited
    case authentication
    case quotaExceeded
    case configuration
    case unknown
  }
}

enum AgentInputAvailability: Equatable, Sendable {
  case prompt(AgentPromptContent)
  case choice
  case unavailable
  case unknown
}

enum AgentPromptContent: Equatable, Sendable {
  case empty
  case occupied
  case unknown
}

struct AgentObservation: Equatable, Sendable {
  let instanceID: AgentInstanceID
  let stateRevision: UInt64
  let sequence: UInt64
  let observedAt: Date
  let state: AgentState
  let inputAvailability: AgentInputAvailability
}
```

`error` is a state with associated detail. There is no parallel optional current
failure field: working with a current failure, and error without failure detail,
are not representable. An unclassified failure uses `reason: .unknown`.

`unknown` means the available evidence does not establish a current state. It
must not become idle or grant input permission by default. `idle` requires a
recognized idle cue. Input availability is a separate fact: a failed Agent may
have a prompt, an error dialog, or an unusable input surface. A prompt also
reports whether its composer is empty, occupied or unreadable; prompt presence
alone is not permission to append text to an existing draft.

`finished` remains an attention presentation, outside AgentState. AgentStateStore
owns focus/seen state and common working stabilization. It may display finished
for an unseen working-to-idle transition; error-to-idle or unknown-to-idle alone
is not proof of successful completion. Focusing an error does not clear it.

The runtime supplies observation identity, sequence and timestamp. The tracker
advances stateRevision on each accepted state transition or positively identified
new occurrence, including a new occurrence with equal failure details. Identical
frames keep the same stateRevision. A capture sequence measures sampling; a state
revision identifies a state occurrence. Parsers never
create UUIDs, read clocks, acquire process data or execute recovery. Runtime-only
observations and recovery tickets are not restored from persisted UI state.

## 2. Pure Agent parsers and terminal-specific evidence

```swift
protocol AgentTerminalParser: Sendable {
  func parse(_ viewport: String) -> TerminalParseResult
}

struct TerminalParseResult: Equatable, Sendable {
  let state: AgentState
  let inputAvailability: AgentInputAvailability
  let evidence: TerminalEvidence
}

struct TerminalEvidence: Equatable, Sendable {
  let currentErrorBanner: ErrorBannerSignature?
  let visibleErrorBanners: Set<ErrorBannerSignature>
}

struct ErrorBannerSignature: Hashable, Sendable {
  let value: String
}
```

Every Agent implements this narrow, terminal-specific protocol. It interprets
its current interaction region, prompt, working/permission cues, error category
and provider retry cues. Common text primitives may be shared; there is no
AgentKind switch in the state store or recovery scheduler.

Terminal evidence belongs to this parsing boundary, not AgentObservation. These
types can be public to cross the Core/App boundary without making terminal
signatures part of the general state contract. A future structured-event decoder
can produce the same AgentState without fabricating viewport text or banners;
no unused generic source protocol is required now.

TerminalParseResult uses controlled construction for errors: an error result
requires a current banner, and that banner must appear in visibleErrorBanners.
For non-error states, currentErrorBanner is nil; historical error banners may
still be visible. Tests enforce this contract for every registered parser.

A per-instance TerminalObservationTracker consumes these results and input
notifications. It owns dismissal signatures and state occurrence bookkeeping;
AgentStateStore consumes only normalized observations and attention events.

The data path is parser candidate -> tracker accepted observation -> Store
presentation. Recovery reads the accepted observation, binding validity and
input facts, never the displayed state. Working hysteresis, finished and seen
are presentation concerns and cannot authorize or reject recovery by themselves.

- Before external input, remember the current banner and invalidate that failure.
- Repainting the same dismissed banner cannot create a new error occurrence.
- A new banner, a confirmed new interaction, or disappearance followed by
  reappearance can establish new error evidence.
- Suppressed error evidence with a positively identified idle prompt becomes
  idle; without a reliable current cue it becomes unknown.
- Working and blocked cues establish progress only when they belong to the
  current interaction region, not merely because they occur in scrollback.

Signatures compare visible text; they are not occurrence IDs. If the same error
recurs without any visible intermediate change, terminal snapshots cannot prove
that it is new. Keep recovery suspended rather than inventing a new occurrence.
The pure parser returns evidence; the tracker owns its lifecycle.

## 3. Error selection is ordered, not a global keyword veto

Each parser determines the latest authoritative cue in its current interaction
region. Retry text elsewhere in the last 24 lines cannot cancel a later terminal
failure. Provider-specific concurrent working/permission cues retain their
explicit precedence only when they describe the active interaction.

| Terminal sequence | State |
| --- | --- |
| Historical reconnect attempts, then final error and prompt | error |
| Historical retry delay, then final API error and prompt | error |
| Error, then a current provider retry countdown | working |
| Error in quoted output or older interaction, then current prompt | idle when the region is identifiable; otherwise unknown |
| Final error with no recognized prompt | error; input availability unknown |
| No recognized current cue | unknown |

The existing 24-line window can remain a bounded heuristic, but is not proof of
recency or ownership. Parsers conservatively report unknown where the terminal
cannot establish the interaction boundary. Do not promise to authenticate exact
quoted provider banners from plain rendered text alone.

## 4. Instance identity precedes observation

```swift
struct AgentInstanceID: Hashable, Sendable {
  let rawValue: UUID
}

struct AgentProcessIdentity: Equatable, Sendable {
  let processID: Int32
  let processStartedAt: Date
  let processGroupID: Int32
}

struct AgentBinding: Equatable, Sendable {
  let instanceID: AgentInstanceID
  let paneID: PaneID
  let surfaceGeneration: UUID
  let kind: AgentKind
  let process: AgentProcessIdentity
  let sessionID: String?
}
```

Extend the shared process probe to identify the actual matched Agent process,
including wrapped CLIs, with PID and birth time. PGID locates a foreground group;
it alone does not identify a child replaced within the same group. If a unique,
live Agent process cannot be established, automatic recovery is unavailable.
Process recognition rules belong to Agent metadata/matching; OS probing remains
shared Runtime code.

Binder issues a new instanceID on process or surface replacement even when kind
and session ID are unchanged. A confirmed switch to a different provider session
also invalidates the binding; enriching a previously unknown session ID for the
same verified session does not by itself imply a restart.

A replacement atomically invalidates the old tracker, observation and recovery
tickets. Never combine an old entry's error state with newly probed process data.
Snapshot capture is tagged with the verified binding and checked against process
identity before and after capture. Late results for an old instance are dropped.

A fresh capture can still contain text left by the old process. Preserve those
old banner signatures as an exclusion baseline, not as state for the new
instance. A new banner/interaction boundary or a session-scoped structured event
must establish new ownership before automatic recovery. Unchanged old terminal
content cannot acquire new ownership merely through a new timestamp.

Transient identity uncertainty suspends automation without clearing attempts.
Restored UI state is display-only until identity and live evidence are verified.
Unchanged text can reuse parsing, but successful captures still refresh liveness;
a changed capture sequence alone does not create a new failure occurrence.

## 5. Recovery consumes facts and keeps a bounded budget

Remove supportsErrorRecovery from AgentTerminalParser. The parser supplies failure
meaning and input availability; shared policy selects actions.

| Failure reason | Default automatic action |
| --- | --- |
| transient | Configured bounded recovery |
| rateLimited | Configured bounded recovery after max(policy delay, retry-after) |
| authentication / quotaExceeded / configuration | Wait for explicit intervention |
| unknown | No automatic action |

An explicitly configured rule may permit a script for other failure categories.
Prompt actions additionally require a verified empty prompt before the first
write and a valid input lease;
scripts do not require a prompt. Recovery remains off by default. Existing
settings decode with conservative defaults for new fields.

```swift
struct RecoveryScope: Hashable, Sendable {
  let instanceID: AgentInstanceID
  let externalInputRevision: UInt64
}

struct RecoveryTicket: Equatable, Sendable {
  let scope: RecoveryScope
  let errorStateRevision: UInt64
  let policyRevision: UInt64
}
```

For an accepted error, the occurrence identity is the pair
(instanceID, stateRevision). The runner copies stateRevision from that observation
into errorStateRevision when scheduling; it never creates an occurrence itself.
Validation requires both the same revision and a current error state.
RecoveryScope owns the attempt
counter separately from the occurrence: error-to-working-to-error, changed error
text, idle/unknown frames and transient probe failures do not replenish attempts.
External input or a new verified instance creates a new scope. A policy edit
invalidates tickets but retains spent attempts in the current scope. Explicit
Cancel marks that scope suppressed, so the next polling tick cannot recreate
the same recovery. Only new external input or a verified new instance clears
this cancellation latch; policy edits alone do not.

| Recovery phase | Behavior |
| --- | --- |
| waiting | Store ticket and deadline; no side effects |
| delivering | Revalidate the frozen ticket and acquire the action lease |
| observing | Action was delivered; await Agent evidence and retain spent attempts |
| suspended | Current activity, uncertain identity, unavailable input or residual draft prevents delivery |
| exhausted | Scope reached its configured attempt limit |
| inactive | No eligible failure, explicit cancellation or ended instance |

At the deadline, obtain a fresh observation for the same binding and require the
same accepted error occurrence. After a suspension, wait a full delay before
acting. An unchanged eligible error may be retried after the configured delay;
attempts remain bounded and actions never overlap for a pane. Count an attempt
immediately before its first side effect, including a paste later interrupted.

Scripts use CommandRunner with timeout, output cap, frozen worktree/context and
lease-driven cancellation. Add instance ID and error-state revision to their environment.
Exit code zero is not proof of Agent recovery. Cancellation cannot undo external
side effects already produced by a script.

## 6. One input coordinator, explicit delivery stages

Runtime owns PaneInputCoordinator; App's TerminalClient and IPC sink delegate to
it. The coordinator accepts generic target/revision validators, not an App-level
recovery runner dependency. The recovery runner supplies ticket validation.

```swift
enum PaneInputOrigin: Sendable {
  case user
  case cli
  case commandQueue
  case recovery(operationID: UUID)
}

enum SubmissionResult: Sendable {
  case submitted
  case cancelledBeforeWrite
  case interruptedWithDraft
  case rejectedDraftPresent
  case targetChanged
}
```

All keyboard, IME, paste, drag/drop, CLI text/key/raw-byte, Send Now, queued command
and recovery paths participate. Programmatic writes go through the coordinator;
native input calls its synchronous pre-input hook before forwarding to Ghostty.
Preserve the existing IME dispatch and notification keystroke semantics; do not
simulate native key events for CLI input or count one IME commit twice.

External input increments the input revision and revokes pending recovery leases
before any bytes are written. Recovery's own writes carry an operation ID and
do not revoke their own lease. Lease validation and the corresponding write run
without an intervening await on MainActor. Coordination is per pane, so unrelated
panes remain independent.

Prompt delivery has four stages:

1. Reserve: validate ticket, process/surface identity and an empty prompt.
   An occupied or unreadable composer cannot receive automatic text.
2. Paste: consume one attempt and record that a draft may now exist.
3. Submit: after the existing delay, freshly validate lease, identity, lack of
   external input, and prompt readiness before sending Return. The composer may
   now be occupied by this operation's paste; this exception requires the
   unchanged lease, not just a matching text string.
4. Interrupt: cancel the delayed Return and retain a residual-draft marker.

Paste is not reversible. After interruption, suspend automatic input and report
that the recovery draft may remain. Native user editing continues; programmatic
submissions are rejected with rejectedDraftPresent rather than appended to the
draft. Explicit user resolution or positively observed submission/clear ends the
marker; arbitrary typing, focus changes or an idle state alone do not.
Never send Ctrl-U, Ctrl-C or backspaces to guess at rollback.

This guarantees no automatic Return after known intervening external input. It
cannot make PTY writes atomic with kernel process replacement, or identify a
draft's owner perfectly from screen text. Stronger submission guarantees require
a provider session-addressed transport with acknowledgements.

## 7. One registry composed from narrow capabilities

```swift
struct AgentDefinition: Sendable {
  let identity: AgentIdentity
  let launch: AgentDescriptor
  let terminalParser: any AgentTerminalParser
  let sessionResumer: (any AgentSessionResumer)?
}

protocol AgentSessionResumer: Sendable {
  func resumeCommand(sessionID: String) -> String
}

enum AgentRegistry {
  static func definition(for kind: AgentKind) -> AgentDefinition
}
```

AgentIdentity holds display/process identity metadata. AgentDescriptor remains
declarative launch data. AgentSessionResumer preserves the current pure resume
command rendering contract, using shared ShellQuoting and adding no profile,
permission or model overrides. Golden command fixtures protect quoting and
resume behavior. No command-string-to-argv migration or Agent-owned subprocess
execution is part of this change.

AgentRegistry is the single exhaustive AgentKind registration. Existing
AgentRuntimeAdapters, AgentCatalog and parser factories become delegating
compatibility facades until their callers migrate. Metadata factories must not
recursively call these facades while constructing a definition.

Each Agent owns its parser, resume implementation where supported, metadata and
fixtures. No dynamic plugin loading, mandatory empty protocol methods or new
Tuist targets are required.

Later extract AgentSessionCodec for per-Agent history layout and record decoding.
Its context includes effective profile HOME and worktree identity; shared local
and SSH scanners retain IO, budgets, sorting, cancellation and path validation.
Do not introduce a history protocol until the existing three codecs and both
transport paths can be migrated and tested together.

## 8. Placement, compatibility and implementation order

| Area | Ownership/change |
| --- | --- |
| CodansCore/Agents | AgentState, failure values, pure terminal parsing/tracker contracts, metadata, registry |
| Runtime/AgentBinder and process probe | Verified process identity and binding replacement |
| Runtime terminal capture | Instance-tagged observations and terminal evidence lifecycle |
| Runtime/PaneInputCoordinator | Per-pane input revisions, leases and submission stages |
| App/Features/AgentState | Shared stabilization, attention and presentation projection |
| App/Features/AgentRecovery | User policy, tickets, budgets and action orchestration |
| Process/CommandRunner | Bounded subprocess execution and cancellation |

Unknown becomes an explicit runtime/wire state; update CLI enum decoding, status,
wait/help and IPC compatibility fixtures together. Preserve the existing finished
presentation for UI/CLI consumers, but do not interpret it as successful execution.
Keep existing settings and persisted display-state decoding compatible; restored
error or finished display never authorizes an action.

Implementation commits, each with focused tests:

1. Unified state/failure model, terminal-specific result/tracker and ordered final-error parsing.
2. Verified instance binding and observation ownership, including restart baseline exclusion.
3. Input coordinator and all entry points; ticket-based recovery and bounded policy.
4. Single registry and compatibility facade migration, with unchanged launch/resume fixtures.

Steps 1-3 form the correctness boundary and must land together before automatic
recovery is enabled. History extraction follows separately. All edits and checks
run in the HAN-167 isolated worktree; the primary checkout remains untouched.

## 9. Acceptance cases

- Every registered Agent has state/parser contract fixtures; error always carries detail.
- Retry history followed by a terminal error yields error; active retry after an error yields working.
- No-match yields unknown; error without a proven empty prompt cannot start prompt recovery.
- A pre-existing composer draft is preserved and prevents an automatic paste.
- Same-kind PID/birth/surface replacement during the waiting period cancels old work.
- Repainting an old process's error does not authorize recovery for its replacement.
- Late observations and action completions cannot update a replacement instance.
- Keyboard/IME/menu paste/drag, CLI, Send Now and queued input revoke recovery before writes.
- External input during paste-to-Return cancels Return and preserves a residual-draft marker.
- A residual draft blocks programmatic appends until positively or explicitly resolved.
- Autonomous activity/error oscillations, policy edits and transient unknown samples do not refill attempts.
- Exhaustion/cancel/pane removal invalidates active leases and cancels scripts without accepting late results.
- Existing launch/resume, settings decode, notification attention and CLI presentation contracts remain covered.

Differential tests remain useful for unaffected Agent cues. Corrected error and
unknown semantics need new expected behavior; reproducing the old implementation
is not their acceptance criterion. Script/prompt unit tests do not substitute for
a real terminal integration test of input routing and draft interruption.
