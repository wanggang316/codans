# Agent integration contracts

**Status:** Implemented and integration-tested on the HAN-167 branch. Not released. See the
[execution plan](../exec-plans/agent-integration-protocols.md) for verification boundaries.

## Scope and ownership

The implementation covers unified Agent state, terminal parsing, verified
instance ownership, recovery scheduling, input coordination, and one Agent
registry. Session-history format and transport extraction remain separate work.

| Concern | Agent-owned contract | Shared responsibility |
| --- | --- | --- |
| Terminal interpretation | `AgentTerminalParser` | Capture, identity, evidence lifecycle and observation acceptance |
| Failure meaning | `AgentFailure` returned as an error state's payload | Recovery policy, delay, attempt budget and cancellation |
| Process recognition | `AgentIdentity` metadata | OS probing, unique process selection and lifetime verification |
| Launch configuration | Declarative `AgentDescriptor` | Profile overrides, environment and execution |
| Session resume | Optional `AgentSessionResumer` | Shell quoting and launch lifecycle |
| Presentation | None | Working hysteresis, focus, seen state and finished attention |

Pure values and parsing live in CodansCore. Runtime owns process probing,
verified terminal capture and `PaneInputCoordinator`. App owns observation
storage, presentation and recovery orchestration. Subprocess execution remains
in the shared CommandRunner. There is no dynamic plugin loader or new module.

## State, evidence and presentation are separate layers

```swift
enum AgentState: Equatable, Sendable {
  case unknown
  case idle
  case working
  case blocked
  case error(AgentFailure)
}

protocol AgentTerminalParser: Sendable {
  func parse(_ viewport: String) -> TerminalParseResult
}
```

`error` is a state with associated failure detail. `AgentFailure` describes the
reason, message, optional provider code and optional retry-after delay. There is
no parallel optional current failure in AgentObservation and no recovery-support
flag on the parsing protocol.

The data path has three distinct steps:

1. **Parser candidate:** `TerminalParseResult` contains AgentState, input
   availability and terminal-specific evidence. Controlled factories require an
   error result to have a current banner that also appears in its visible banner
   set. Non-error results cannot carry a current error banner.
2. **Accepted observation:** a per-instance `TerminalObservationTracker` applies
   dismissal and ownership exclusions, then produces AgentObservation with
   instance ID, state revision, sequence, observation time, state and input facts.
   Terminal signatures remain in the tracker rather than the generic observation.
3. **Presentation:** AgentStateStore applies working hysteresis and attention to
   accepted facts. UI/CLI may display `finished` for an unseen working-to-idle
   transition. Recovery reads the accepted observation, never this display state.

`unknown` means the evidence does not establish a current state. It neither
implies idle nor grants input permission. Input availability distinguishes a
prompt, a choice, unavailable input and unknown input; a prompt separately reports
empty, occupied or unknown content. Error state alone cannot authorize a paste.

Focus clears attention without dismissing errors. Error, blocked and unknown
presentation clears a previous finished indication. Neither an error-to-idle
transition nor restored UI state proves successful execution.

## Ordered parsing and evidence lifecycle

Each Agent owns its terminal grammar. Codex and Claude Code currently recognize
a bounded set of failure banners. Their parser orders current interaction cues:
a final error after historical retry text remains an error; a current provider
retry after an error is working. A global occurrence of the word retry cannot
veto a later failure. Quoted/code text, recognizable previous interactions and
unsupported cues are handled conservatively.

| Current interaction evidence | Accepted candidate |
| --- | --- |
| Historical reconnect attempts, then final failure and prompt | error |
| Error, then current retry countdown | working |
| Error with no recognized composer | error, input unknown |
| Positively recognized idle prompt | idle with composer facts |
| No recognized current cue | unknown |

Before external input, the tracker remembers the current error banner and
invalidates that observation. Repainting a dismissed banner cannot create a new
failure occurrence. A new banner, disappearance followed by reappearance, or
confirmed working/blocked interaction can establish new evidence. A suppressed
banner with a recognized prompt yields idle; without one it yields unknown.

Capture sequence measures sampling, while state revision identifies accepted
state changes or a new accepted banner. Identical captures refresh liveness but
keep the state revision. A repeated identical error without a visible intervening
change cannot be proven new from terminal text; it remains suppressed when its
previous occurrence was dismissed. Parsers do not generate IDs, read clocks,
probe processes or trigger actions.

## Instance ownership precedes observation

`AgentBinding` contains an instance ID, pane ID, surface generation, Agent kind,
actual process identity and optional session ID. `AgentProcessIdentity` combines
PID, process birth time and foreground process group ID. PGID locates the group;
it is not a substitute for the actual Agent process, including wrapped CLIs.
Ambiguous matches and missing birth times cannot authorize automation.

AgentBinder creates a new instance when the process, surface or a confirmed
session changes. Enriching an unknown session ID for the same process preserves
the instance. Verified bindings and legacy display-only bindings use separate
callbacks; a display callback cannot reset a verified tracker's evidence.
Transient uncertainty suspends the binding without replenishing its recovery
budget. Repeated empty OS probes do not count as a confirmed instance exit.

TerminalEngine verifies ownership before and after reading the active terminal
region. `AgentTerminalSnapshot` carries the binding, capture sequence, time and
text. The store rejects mismatched bindings and non-increasing capture sequences.
A successful capture is emitted even when text is unchanged; parsing can reuse
the cached result while liveness advances. Recovery requests a fresh capture
against the already established binding at validation time.

A replacement's first frame may still contain its predecessor's final output,
including a banner painted after the predecessor's last sample. The store uses
all visible error banners in that first replacement frame as an exclusion
baseline. Subsequent new evidence must establish ownership before recovery can
act. A new process identity and timestamp alone cannot give old text new ownership.
This is deliberately conservative: an actual new failure already present in the
first replacement frame may also wait for subsequent evidence or intervention.

Untagged/remote viewport events and restored UI snapshots remain useful for
display, but cannot authorize local automatic recovery. SSH projects are excluded
from the recovery target list.

## Recovery policy and bounded attempts

Agent-specific parsing supplies failure meaning. Shared AgentRecoveryPolicy
selects actions:

| Failure reason | Default automatic action |
| --- | --- |
| transient | Configured bounded action |
| rateLimited | Configured action after max(policy delay, provider retry-after) |
| authentication, quotaExceeded, configuration, unknown | Wait for intervention |

Explicit `additionalScriptReasons` may permit a configured script for other
categories. It never broadens prompt recovery. Recovery is disabled by default;
older settings decode missing policy fields conservatively.

`AgentRecoveryRunner.Scope` is `(instanceID, externalInputRevision)`. Its attempt
counter survives error/working/idle/unknown oscillations and temporary identity
uncertainty. A new verified instance or external input creates a new scope.
Policy edits invalidate tickets but retain the current scope's spent attempts.
Explicit Cancel latches suppression until external input or a new instance;
policy edits do not clear that latch. Runtime budgets are not persisted.

`AgentRecoveryRunner.Ticket` freezes the binding, scope, accepted error's state
revision and policy revision. The runner validates current identity, fresh
accepted evidence, that error occurrence, policy and input restrictions before
starting. Suspended or changed occurrences wait a full delay. Only one action per
pane is active, and completion starts the next delay. Prompt attempts are counted
at the guarded first paste; the script path counts at dispatch into CommandRunner.
A cancelled paste still consumes its attempt.

Prompt recovery additionally requires an empty composer and an input lease.
Scripts do not require a composer; they use the captured worktree context,
CommandRunner timeout/output bounds and cancellation from the recovery task.
Script exit status does not establish Agent success. Already executed external
side effects cannot be rolled back.

## Input coordination and interrupted drafts

PaneInputCoordinator participates in native keyboard/IME/paste/drag input, CLI
text/key/raw-byte input, Send Now, queued commands, Handoff instructions and
receiver kickoff, and recovery submissions.
External intent advances the pane's input revision and revokes older operations
before bytes are written. Recovery writes carry their own operation ID and do
not invalidate their own lease. Physical-keystroke notification timing remains
separate from input ownership.

A recovery prompt submission reserves a lease, checks the target and empty composer,
pastes, waits the existing 150 ms submission gap, then revalidates before Return.
After this operation's paste, an occupied composer is allowed only while its
lease remains valid. Validation and the corresponding write share one MainActor
turn without an intervening await.

Interruption after paste leaves a residual-draft marker. Native user editing
continues, but programmatic appends are rejected rather than combined with that
draft. CLI callers receive a `conflict` explaining the rejected input, rather
than a false pane-not-found error. The Agent row exposes explicit confirmation
that the user cleared the recovery draft. The pane actions menu also provides
**I Cleared the Draft**, including after the Agent has exited. Explicit interrupts
remain available; an empty text write does not revoke a lease.

Automatic clearing requires an observed occupied composer followed by an empty
composer while the marker is present. A first empty frame may predate rendering
of the paste and is insufficient. Typing, focus, generic idle state and unknown
composer content do not clear the marker. Lifecycle and membership cleanup
remove pane coordination state; late operation completions cannot recreate it.
No rollback guesses using Ctrl-U, Ctrl-C or backspaces are made.

PTY writes still cannot be atomic with kernel process replacement. Stronger
submission guarantees require a provider session-addressed transport with
acknowledgements. A real Ghostty/PTY test verifies draft rejection and resumed
delivery; the execution plan distinguishes it from real provider recovery.

## One registry and compatibility boundaries

`AgentRegistry` is the single exhaustive AgentKind registration. Each
AgentDefinition composes AgentIdentity, declarative launch metadata, a terminal
parser and an optional session resumer. AgentRuntimeAdapters, AgentCatalog and
AgentObservationParsers delegate to it as compatibility facades. Registry
construction does not call those facades recursively.

Existing launch interaction, profile overrides and shell-quoted resume commands
remain unchanged. Session resume does not add execution-mode overrides or mutate
the source session. History readers still own their current formats and local/SSH
IO; extracting all three formats and both transports together is follow-up work.

UI and IPC retain existing state spellings and add explicit `unknown`. CLI status,
wait conditions and help expose it. Old stored display-state values remain valid;
clients consuming the new state must accept the additional value. Neither an old
restored error/finished badge nor an unknown observation authorizes recovery.
