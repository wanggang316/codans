# Agent Error Recovery

**Status:** Implemented and exposed in the HAN-167 branch; not released.

Codans recognizes a limited set of terminal failure banners for Codex and Claude Code. A recognized error appears as `error` in Agents View and `agent status`; `agent wait --until error` waits for it. Merely focusing the pane does not dismiss the error.

## Detection and evidence

The existing state source is the rendered active terminal region, not a transcript tail or an Agent hook. The classifier examines recent lines and accepts only a trailing error banner (allowing an empty prompt and horizontal borders below it):

- Claude Code: `API Error: ...`, optionally prefixed by its `⎿` marker.
- Codex: a `■` error marker with one of the recognized stream-disconnection, unexpected-status, exhausted-retry or usage-limit messages.

Working and permission indicators take precedence. Retry/reconnect indicators and fenced code suppress error matching. Generic `error` words, shell exit codes and failed tool results are not Agent failure signals. Text matching is necessarily heuristic: version changes, wrapped errors, footer content and localization can cause missed errors, and identical quoted banners cannot be authenticated as provider events. Unsupported Agent kinds retain their existing classification.

A restored error badge cannot dispatch recovery until a live viewport confirms the error. Keyboard activity suppresses the previous error fingerprint so repainting the same failed request cannot consume the user's new input. Binding changes invalidate the old viewport.

### Structured-event alternatives

Verified against official documentation on 2026-09-25:

- [Codex App Server errors](https://learn.chatgpt.com/docs/app-server#errors) provide an error notification and a failed turn status with categorized error information. Adopting this source requires owning/subscribing to the relevant app-server session; Codans currently embeds terminal CLIs and does not have that connection.
- [Claude Code StopFailure](https://code.claude.com/docs/en/hooks#stopfailure) supplies session context and an API error category. Hook output does not resume a failed turn. Using it in Codans requires hook installation, a validated IPC event entry point and session-to-pane association; none is installed by this feature.

These are preferred future event sources, not implemented capabilities. Existing session-history readers are not error monitors.

## Configuration

Settings → Agents → Error Recovery controls an opt-in policy shared by supported local Agent panes. It is disabled by default, including when an older settings file has no recovery key.

- **Send Prompt** pastes the configured text and submits it with a separate Return.
- **Run Script** invokes `/bin/zsh -lc` through the shared `CommandRunner`, outside the Agent terminal, with the owning worktree as cwd. It does not automatically send a follow-up prompt.
- Delay: 5–3600 seconds; maximum attempts: 1–10. Defaults: 30 seconds and 3 attempts.
- Empty action text or invalid bounds prevent dispatch. SSH projects are excluded.

Scripts receive `CODANS_PANE_ID`, `CODANS_AGENT_KIND`, `CODANS_AGENT_SESSION_ID` (possibly empty), and `CODANS_RECOVERY_ATTEMPT`. Each command has a 30-second timeout and a 64 KiB capture limit. Exit status is logged; script success does not establish Agent success.

## Scheduling and cancellation

Recovery uses a dedicated runner rather than scheduled command-queue entries. Ordinary scheduled commands retain their wall-clock behavior; delivering one invalidates pending recovery for the pane.

The runner checks the policy, pane binding generation, Agent kind/session, worktree path, live surface, freshly read foreground Agent process group/start time and current error before each action. It waits the configured delay after observing an error and after completing an attempt. Only one recovery action per pane may be active. Working or blocked states pause recovery, and a subsequent error must wait a fresh delay.

Spent attempts survive working/error and idle/error oscillations. The budget resets only after user input, rebinding, a policy change, or the target leaving the runner. No timer or last-error repaint grants another budget. Runtime attempts are not persisted across app launches.

The prompt sender checks identity again before Return, allowing the paste itself to change an error screen into an idle composer but rejecting working/blocked states or a replaced surface. If input or cancellation intervenes after paste, the text may remain unsubmitted; Codans does not erase the user's composer.

Use the error row's **Cancel Automatic Recovery** context-menu action to disable recovery for that binding until new keyboard input or rebinding. The error badge remains visible. Disabling recovery globally also invalidates pending actions. Already-started external script side effects cannot be rolled back.

## Verification

Classifier fixtures cover positive banners and negative prose/tool/retry cases. State tests cover focus, user input, stale screenshots, restored state and rebinds. Recovery-runner tests use an injected clock and delivery function to verify delay, attempt limits, stale identity, cancellation and script arguments. The command queue's existing readiness behavior remains covered separately.

Live provider outages and real remote sessions are not part of automated verification. Do not infer complete Agent-version coverage from fixture tests.
