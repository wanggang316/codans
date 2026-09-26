# Agent Error Recovery

**Status:** Implemented and integration-tested on the HAN-167 branch. Not released. Architecture and ownership are defined
in [Agent integration contracts](agent-integration-protocols.md).

## State and detection

`error(AgentFailure)` is part of the unified AgentState alongside unknown, idle,
working and blocked. Failure detail identifies a reason, message, optional
provider code and optional retry-after delay. The UI and `agent status` project
this as `error`; `agent wait --until error` waits for that presentation. Focusing
the pane does not dismiss the error. `unknown` is explicit and does not mean idle
or ready for input.

The implemented source is the rendered active terminal region. Pure per-Agent
parsers produce state, composer facts and terminal evidence; a per-instance
tracker accepts or suppresses that evidence before the store projects UI state.
Recovery consumes accepted observations and verified bindings, not display
hysteresis or the `finished` attention indication.

Recognized failure grammar currently includes:

- Claude Code: `API Error: ...`, optionally prefixed by `⎿`.
- Codex: a `■` marker with recognized stream-disconnection, unexpected-status,
  exhausted-retry or usage-limit messages.

Final-error recognition uses ordered interaction cues. Historical retries do not
hide a later final failure; a newer active retry pauses external recovery. An
error without a proven composer can still be reported, but cannot start prompt
recovery. Generic error words, failed tool output and shell exit codes do not
establish an Agent failure. Terminal formats, wrapped output, footers and
localization remain heuristic boundaries; fixture tests do not establish support
for every Agent version or authenticate quoted provider text.

External input invalidates the current failure and suppresses its old visible
banner. A new banner, a new confirmed interaction, or disappearance and
reappearance can establish fresh evidence. Identical screenshots renew liveness
without manufacturing new failure occurrences.

## Ownership and replacement

Recovery targets an existing AgentBinding: instance ID, pane, surface generation,
kind, actual Agent PID/birth time/PGID and optional session. The process matcher
requires a unique Agent process, including wrapped CLIs. A group leader alone is
not sufficient identity. New process, surface or confirmed session replaces the
instance; temporary uncertainty pauses automation without restoring attempts.

Each terminal capture checks the same binding before and after the read. Old
instance results and out-of-order sequences are rejected. Replacing a process
cannot combine the new process identity with an old accepted error.

The replacement's first frame also becomes an error exclusion baseline: the
predecessor may have painted its final banner between sampling ticks. Those
banners cannot authorize recovery until subsequent evidence establishes a new
interaction. This conservative boundary may also defer an immediate failure of
the replacement. Restored badges and remote/display-only observations never
authorize a local action.

## Policy and configuration

Settings → Agents → Error Recovery configures an opt-in policy. Missing settings
retain the disabled default. Eligibility depends on failure meaning and current
facts, not an Agent-name allowlist or a parser capability flag.

| Failure reason | Default behavior |
| --- | --- |
| transient | Permit configured bounded recovery |
| rateLimited | Permit recovery after max(configured delay, retry-after) |
| authentication, quotaExceeded, configuration, unknown | Require intervention |

A script may explicitly opt into additional failure reasons. Prompt actions
remain restricted to transient/rate-limited failures and a verified empty prompt.

- **Send Prompt:** paste configured text, then revalidate before a separate Return.
- **Run Script:** invoke `/bin/zsh -lc` through CommandRunner outside the Agent
  terminal, with the captured worktree directory as cwd; no implicit prompt follows.
- Delay: 5–3600 seconds, default 30; attempts: 1–10, default 3.
- Empty action text or invalid bounds prevent dispatch. SSH projects are excluded.

Scripts receive `CODANS_PANE_ID`, `CODANS_AGENT_KIND`, `CODANS_AGENT_SESSION_ID`
(possibly empty), `CODANS_AGENT_INSTANCE_ID`, `CODANS_ERROR_STATE_REVISION` and
`CODANS_RECOVERY_ATTEMPT`. CommandRunner applies a 30-second timeout and a 64 KiB
capture cap. Exit status is logged; success does not prove the Agent recovered.

## Scheduling, cancellation and input

A recovery scope combines instance ID and external-input revision. Its bounded
attempt counter survives autonomous state oscillations and temporary probe
failures. External input or a new instance creates a new scope. Policy edits
invalidate pending tickets without replenishing the current scope's budget.
Budgets are runtime-only and are not persisted across app launches.

A ticket records the binding, scope, accepted error-state revision and policy
revision. At dispatch the runner obtains a fresh capture and checks the same
accepted occurrence. A suspended or changed occurrence waits a full delay;
completion also starts the next delay. Only one action per pane runs at a time.
Prompt attempts count at the first paste, including a paste later interrupted;
scripts count at dispatch into CommandRunner.

PaneInputCoordinator synchronizes native input, CLI writes, Send Now, command
queues, Handoff instructions/receiver kickoff and recovery prompt delivery. External input revokes pending recovery
before the write. Recovery's own operation retains its lease across the 150 ms
paste-to-Return gap; Return requires a fresh valid target, unchanged lease and
recognized composer. Scripts are cancelled through their recovery task when the
scope or applicable state is invalidated.

If a paste is interrupted, its text may remain in the composer. Codans records a
residual draft and rejects programmatic appends. CLI rejection is a `conflict`,
not a nonexistent-pane error. Native editing remains available. Clear the draft
and use **I Cleared the Recovery Draft** in the Agent row or **I Cleared the Draft**
in the pane actions menu (also available after Agent exit), or let a verified
occupied-to-empty composer transition clear the marker. A first empty screenshot,
focus, typing or idle state alone cannot prove the paste is gone.

**Cancel Automatic Recovery** suppresses the current scope until external input
or a new verified instance; policy edits alone do not clear cancellation. Global
disable invalidates pending actions. Lifecycle/membership teardown removes pane
coordination state. Already-started script side effects cannot be rolled back.

## Structured-event alternatives

The following alternatives were researched against official documentation on
2026-09-25; neither is installed or subscribed to by this implementation:

- [Codex App Server errors](https://learn.chatgpt.com/docs/app-server#errors)
  expose structured failure information, but require access to the relevant
  app-server session rather than only the embedded CLI terminal.
- [Claude Code StopFailure](https://code.claude.com/docs/en/hooks#stopfailure)
  supplies session/error context. Adoption needs hook installation, a validated
  IPC entry point and session-to-pane association; hook output itself does not
  resume a failed turn.

A future decoder may produce the same AgentState without terminal banner
signatures. Existing session-history readers are not live error monitors.

## Verification boundary

Independent harnesses cover parser contracts, ordered errors, policy, instance
replacement, input revocation, bounded attempts and residual-draft transitions.
Final integrated App/CLI verification is tracked in the
[execution plan](../exec-plans/agent-integration-protocols.md).

No live provider outage, real automatic-recovery session or GUI validation is
claimed by these tests. PTY writes remain subject to a kernel process replacement
race; session-addressed provider transports would be needed for stronger guarantees.
