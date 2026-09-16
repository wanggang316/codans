# Workflow implementation plan

Status: Initial implementation with GUI creation and fixed serial dispatch. Build, targeted regression tests, and a real Advisor dispatch/delivery smoke test have passed. Authorized on 2026-09-16; commit verified assistant changes without pushing.

Design status: The fixed-template product model was rejected after review. The replacement proposal is [Agent Workflows v2](design-docs/agent-workflows-v2.md), which separates YAML definitions, roles, run bindings, and management surfaces. The implementation inventory below remains historical evidence of the current slice; it does not mean v2 is implemented.

## Implemented scope

The current slice builds a shared execution protocol for Handoff, Advisor, and Committee using fixed built-in templates. It does not implement the full dynamic-plan architecture.

1. **Core:** typed runs, step dependencies, attempts, idempotent deliveries, cancellation, and interruption. `AgentWorkflowRun` avoids the existing GitHub Actions `WorkflowRun` name.
2. **Persistence:** app-owned store, bounded atomic snapshots, persistence before acknowledgement, execution configuration and dispatch records, visible load/write errors, and interruption on restart.
3. **IPC/CLI:** create/list/status/claim/deliver/cancel with shared wire types. Plain CLI creation remains explicit pull/claim; GUI-created Advisor/Committee runs additionally configure the runner.
4. **GUI creation:** Workflows → New Workflow and Show Workflows; title, multiline question/briefing, workspace selection, enabled agent profiles, Committee's second profile, and Handoff's source pane. Creation retains its command identity on failure and selects the resulting run on success.
5. **Advisor/Committee dispatch:** automatically launch each eligible agent step in a new background tab, serially. Prompts include explicit claim/delivery instructions. Initial Committee analyses do not include each other's report; cross-review and synthesis receive the accepted dependencies. Dispatch uncertainty is recorded rather than automatically retried.
6. **User decisions and recovery:** Advisor's Adopt / Need more evidence / Reject controls record a reason without launching another agent. Eligible Advisor advice and Committee steps also support explicitly manual result recording. Export, receive, and disposition are excluded from that recovery route.
7. **Handoff:** GUI and existing CLI/UI entry points share handlers. Packet persistence precedes export; export acceptance follows the actual compatibility-file write. Receiver acknowledgement uses the immutable packet digest and bound pane. Handoff launch does not imply receiver acceptance or permission to edit.
8. **Run UI:** reports, advice, dispatch/waiting state, agent navigation, step details, events, visible errors, and cancellation share the same store as CLI operations.

## Deliberate boundaries

All templates are serial, including Committee. Each automatic agent step starts a fresh tab; profile selection may be shared across roles. Read-only prompts are not a filesystem sandbox and nonempty reports are not semantic verification.

The Advisor decision form is implemented; a general Human-node system is not. Recording “Need more evidence” does not schedule additional work. Manual result entry records the user's submission and can advance dependencies, but does not stop the original agent.

Cancellation stops scheduling and further acceptance, not processes or file changes. Unfinished runs become interrupted after restart, without automatic replay; existing agents may still run. Dynamic plan edits, scoped attempt credentials, automatic retry/resume, coordinator transfer, parallel scheduling, separate WorkItem acceptance, and writer ownership transfer remain future work.

Do not label the full architecture or all WF/HC/AC/CC acceptance criteria complete based on this slice.

## Verification on 2026-09-16

- App Debug and CLI Debug builds passed with Xcode 26.0.1.
- 48 tests passed across AgentWorkflowStoreTests, AgentWorkflowRunnerTests, WorkflowRouterTests, HandoffHandlersTests, and HandoffFeatureTests. This covers the five-stage Committee sequence with injected launchers, input isolation, cancellation, failed writes, manual results, idempotent claims, and unclaimed-dispatch timeout.
- Interactive New Workflow menu and form verified: workspace/profile selection, disabled empty submission, creation, run selection, dispatch history, and Open Agent navigation.
- A real Claude Code Advisor launched from the GUI in an empty temporary workspace, claimed its bound step, and submitted an accepted report through the bundled CLI. The run correctly waited for the human disposition. The run ID is `865074D9-BA7E-4804-BD4F-0D6F5BED22C9`.
- The computer-use bridge then returned `native pipe closed before response`; completing the disposition form interactively could not be verified. Its store transition is covered by tests. Full live Committee and Handoff GUI runs have not been exercised in this update; do not equate injected-launch tests with third-party Agent compliance.
- `make mac-check` ran. It reported existing repository-wide lint failures; unrelated formatter changes were reverted after byte-for-byte checks. Changed-file lint and `git diff --check` passed. The final 18-test Handoff regression suite also passed after preserving GUI titles and replacing a scheduler-dependent test wait with a bounded receipt wait.
- Logs and snapshots: `/tmp/codans-workflow-build` on the development machine. The previous slice's Core and Release CLI checks are historical evidence, not reruns of this update.

## Follow-up sequence

Use the replacement design's implementation sequence after model review. Do not extend the fixed-template composer or make Workspace a required field of every workflow. Preserve historical run records and explicit delivery invariants while replacing definition loading, role binding, dispatch, and the management UI. Writer admission and continuation authorization must precede automatic editing workflows.
