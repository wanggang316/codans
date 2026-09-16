# Workflow v2 implementation and GUI acceptance

Status: Implementation built; 48 focused tests passed. Real GUI case execution is pending. Authorized implementation and complete GUI case execution.

## Scope

Replace the fixed-template creation entry with YAML definition management, runtime
Role binding, a generic Action dispatcher, explicit deliveries, durable history
and generated run setup. Preserve old runs without interpreting them as v2 runs.
Use the five reviewed definitions as production resources; scenario results must
never be used by the application.

## Sequence

1. Implement the parser, validation, built-in/user definition catalog and tests.
2. Implement durable run state, native Actions, terminal adapters and receipt
   routing through the existing workflow CLI protocol.
3. Integrate definition creation/source management, role-based run setup and
   run details with human decisions into the native app.
4. Build app/CLI, run focused tests and hygiene checks; commit own verified files.
5. Launch the built app and use its GUI to run Decision Only, Advisor, Committee,
   Handoff and Handoff from Briefing. Use real terminal Agents, inspect accepted
   results, finish human decisions, inspect source and persisted history.
6. Record run IDs and evidence, fix observed failures, rerun affected cases and
   commit the final verified changes.

## Acceptance boundaries

No mandatory Session or Workspace for Decision Only. Launch configuration belongs
to each launch Role. Current/pick bind existing live Agents; repeated actions on
one Role reuse its endpoint. Initial Committee requests do not include peer
reports. Handoff cannot finish on launch alone; packet-correlated receipt is
required. Invalid delivery remains visible and correctable. Application restart
must preserve history without replaying external effects.

GUI checks must exercise the actual new app, not synthetic fixture traces. An
external Agent/service failure must be recorded as a real limitation and cannot
be replaced by manually supplying its result while claiming an automated pass.

## Verification before GUI acceptance

- App Debug build passed.
- 48 tests across parser/catalog, service, endpoint identity, new/legacy routing and Agent state passed.
- Full `make mac-check` ran; unrelated formatter-only changes were restored. New v2 files pass focused lint. Existing MethodRouter routeProject async and AgentStateStore refresh complexity findings remain outside this change.

## Prowl-aligned navigation correction

Workflow does not own a separate window. Definition management lives in the
existing Settings window under Agents → Workflows: a compact Built-in / Your
Workflows index pushes definition details, YAML source and execution history.
Main-window workflow controls start a run and inspect history in a sheet without
leaving the terminal workspace. Role launch locations remain per-run bindings.

Reference: Prowl `WorkflowsSettingsView`, `WorkflowSettingsDetailView`,
`AgentsToolbarButton`, and `WorkflowStepHistoryView` in the local source checkout.
The prior separate-window arrangement is superseded. GUI acceptance remains
pending; the computer-use service crashed reading the previous standalone
window, independently of the application process.

### Navigation verification (2026-09-16)

- Debug build and 13 selected parser/catalog, service and router regression tests passed.
- All changed Swift files passed focused SwiftLint; `git diff --check` passed.
- GUI verified the existing Settings window (`id: settings`) renders Built-in,
  Your Workflows, creation/import/refresh actions and execution history.
- GUI found and fixed first-use run-sheet state capture: one typed presentation
  value now carries either a definition or a history destination. Run and History
  use distinct toolbar items and accessibility labels.
- Decision Only completed entirely through the main-window GUI: run
  `54224675-405D-4A49-94D4-7A49695F09FE`, status `succeeded`; no agent/workspace
  fields, decision and reason recorded, full Frozen YAML inspected.
- Definition-detail navigation still triggers a crash in SkyComputerUseService
  (`Array.remove(at:)`), so that path is not GUI-accepted yet.
- Advisor GUI exposed a real prompt transport bug: `sendInput` emits Return for
  each newline. Kickoff now uses the existing bracketed-paste `sendText` path.
  Failed run `2890598F-6257-4BCA-9CD2-E3A2F638C9B0` remains in history.
  New run `83C3A9BE-22CB-4F82-8788-905CF8BFE935` reused the same Claude pane,
  accepted its real delivery, and succeeded after a GUI human decision.
- Definition overview now follows Prowl's grouped Form/Section layout; built
  successfully, awaiting a fresh-process GUI retest.
- Handoff from Briefing was started through the GUI as run
  `9E8C6C92-65A9-4482-9D3C-3161F0B3AF53`. The receiver opened on Claude's
  session dashboard with pending text; GUI focus plus Return was required to
  submit it. The real receiver retrieved the packet and delivered its receipt;
  CLI snapshot confirms all four nodes succeeded. Final GUI result inspection
  and unattended first-request submission remain unverified.
- Committee run `34FABFC7-8DE2-447E-8D3A-25230AE89B5C` was configured and started
  through the GUI. Both analyst sessions launched; analyst A is awaiting a
  delivery, later analysis/review/synthesis nodes remain pending. It is not an
  accepted case yet.
- GUI work paused when computer-use reported the Mac locked again. Remaining:
  resume Committee, verify Handoff from Briefing's final GUI state, run Handoff,
  retest grouped definition details/YAML/new-definition navigation, and inspect
  persisted history after restart once active runs have ended. Do not restart
  the app while Committee remains active merely to test the definition layout.

### Follow-up GUI verification

- The grouped definition Overview is GUI-verified. Created personal definition
  `user.aad87055-db19-4176-865d-5f2a91703dd3` in Settings, edited its YAML,
  saved it, and verified its updated description in Overview. Navigation stayed
  within the existing Settings window.
- Inputs & Results now uses native Form/Section layout. Its inputs, outputs and
  participant controls were inspected through the GUI without an accessibility
  parser failure.
- The earlier Briefing Handoff success is not an accepted isolation result:
  Claude Agent View dispatched through a shared background host with another
  role's inherited pane ID. Committee was cancelled to prevent further dispatch.
- Workflow-launched Claude profiles now copy the selected profile and disable
  Agent View only for that launch. Saved profiles and their permission settings
  are unchanged. Debug build 9 passed.
- GUI run `3DD18724-0AB6-4166-B37F-0E7C6D5ADE09` opened an independent foreground
  Claude receiver, but its initial request was not submitted. History records
  the uncertain submission as failed without retrying. First-request readiness
  remains under investigation; this run is not an accepted case.

- Claude requests now require a stable empty bordered composer before the first
  write. Startup screens, existing drafts, working and blocked screens cannot
  satisfy readiness. No uncertain submission is automatically resent.
- Debug build 10 passed; 43 readiness/attention tests and 18 V2 regression tests
  passed. Segmented navigation labels no longer consume visible header width.
- Fixed incremental CLI embedding deleting its sibling `zmx` binary. Each embed
  script now replaces only its declared output; two consecutive fixture updates
  preserve zmx content and execution permissions.
- Briefing Handoff `6D45A442-386E-42E3-BFED-75002DC8CC56` is GUI-accepted: all four
  nodes succeeded without manual prompt submission. Receiver D8D2B074 matched the
  actual foreground Claude process environment and its accepted delivery.
- Full Handoff `9AC7AC68-7F4D-4057-A814-C19D0B6F149A` is GUI-accepted: the previous
  receiver authored a briefing from its actual conversation, a new receiver read
  and acknowledged the immutable packet, all five nodes succeeded, and the GUI
  displayed the preserved context and `readiness: ready`.
- Committee `077AC63F-84BF-4604-B69D-4BCBA094E84F` is running with two separately
  launched analysts and an existing independent foreground synthesizer.

### Completed acceptance cases

All five bundled definitions have completed through the real GUI. Agent output
was delivered by the actual agents through the CLI; the test driver did not
supply synthetic deliveries.

| Definition | Accepted run | Verified behavior |
| --- | --- | --- |
| Decision Only | `54224675-405D-4A49-94D4-7A49695F09FE` | Agent-free launch, explicit decision and reason, frozen YAML |
| Advisor | `83C3A9BE-22CB-4F82-8788-905CF8BFE935` | Existing Agent delivery followed by GUI human decision |
| Handoff from Briefing | `6D45A442-386E-42E3-BFED-75002DC8CC56` | Immutable packet, independent receiver, accepted receipt and digest verification |
| Handoff | `9AC7AC68-7F4D-4057-A814-C19D0B6F149A` | Existing conversation briefing, independent receiver, five completed nodes |
| Committee | `077AC63F-84BF-4604-B69D-4BCBA094E84F` | Two independent analyses, same-role session reuse for two reviews, final synthesis |

Committee completed all seven nodes and five real deliveries. Its final GUI
report contains Consensus, Disagreements and Recommendation, retaining the
unresolved choice between a reminder/escalation and automatic retry. Analyst A
used pane B423B014 for both analysis and review; analyst B used 1219EB48; the
synthesizer used 5C2A28FE. Foreground process identities matched these bindings.

Settings definition creation, YAML edit/save, pushed detail navigation and main
window execution history are GUI-verified. Restart preserved completed runs,
inputs, outputs, decisions and event history. Failed attempts remain visible.
These acceptance runs use the installed Claude version; they do not establish
compatibility with every other Agent profile or future TUI changes.

Final incremental Debug build 11 succeeded with both bundled CLI and zmx
executable. A final GUI restart restored the terminals and all five accepted
runs; Committee still showed all seven nodes succeeded. The history sheet is
left open on that result for inspection.

### Execution and navigation correction

User acceptance supersedes the previous GUI acceptance: successful fixture runs
were insufficient to validate real launch behavior and navigation.

- Make Workflows a peer Settings item; remove every run/history route there.
- Put a grouped Run/History control immediately before Agents on the trailing toolbar.
- Remove the menu-bar Workflows menu.
- Start closes parameter entry and presents the current execution, never the historical list.
- History uses Prowl's hover preview, click-to-pin and list-to-detail popover pattern.
- Reproduce the user's OMP Handoff failure, fix collapsed-paste detection with
  before/after evidence, and verify through the main GUI with that Agent kind.
- Verify settings, toolbar order, absence of menu, launch feedback, human action,
  history drill-down and terminal continuation; commit only owned changes.

#### Verified correction cases

- Settings now presents Workflows alongside Agents, with Overview and YAML Source
  for definitions and no execution history section. The main toolbar groups Run
  and History before Agents, and the menu bar has no Workflows menu (GUI checked).
- Decision Only `CE05309F-729C-49C9-9347-4E37FE1D8962` started from the parameter
  form into Current Workflow, displayed the proposal inline and “Waiting for your
  decision”, and completed after a real GUI decision.
- OMP-to-OMP Handoff `70714A6E-9D2C-4BB5-93B7-EE853ED4680B` started through the GUI
  using existing OMP pane `CC9B7109` and a new OMP receiver. The author claimed and
  delivered its briefing; the receiver independently hashed the immutable packet,
  claimed its own attempt, and delivered an accepted receipt. The GUI showed
  Completed. No test-driver delivery or manual prompt submission was used. This
  workflow ends at acknowledgement; execution of the handed-off task is separate.
- The prior user OMP failure was an unrecognized folded multiline attachment.
  Submission now requires before/after evidence of a new matching attachment. An
  existing unsent attachment is preserved and rejected with an actionable error.
  The user's existing failed-run draft was not submitted or cleared.
- Final Debug build 5 succeeded. After restarting that build, GUI history click
  opened the OMP run with all five nodes Completed; Back returned to the list,
  Close returned to the terminal. Explicit full-width buttons replaced native
  List rows whose click did not activate the detail. Settings hierarchy and the
  absence of history were rechecked on this final build.
- Final regression: 20 tests across AgentKickoffEcho, WorkflowServiceV2,
  WorkflowLaunchProfileV2, WorkflowDefinitionV2 and WorkflowRouterV2 passed.
  Focused SwiftLint passed for the changed Swift files. Logs and xcresult:
  `/tmp/codans-workflow-v2-build/navigation-correction-final-tests.*`.

### Remove unreleased legacy runs

Keep one run model and store: remove template-run UI, model, runner, storage and
IPC fallback rather than migrate them. Remove obsolete template-based CLI create
and standalone Handoff's duplicate old-run recording. Preserve current DSL
Handoff behavior and the standalone Handoff artifact/launch operations. Validate
current routing, missing-run errors, delivery and Handoff regression tests before
committing; existing old files need no migration or destructive cleanup.

Validation completed for legacy removal:

- Focused `swift-format` and `swiftlint lint --use-script-input-files` passed
  for all 11 changed or new Swift files that remain on disk. The router's
  synchronous project dispatch no longer declares an unused `async` boundary.
- From `apps/mac`, `xcodebuild -workspace codans.xcworkspace -scheme Codans
  -configuration Debug build` and the equivalent `-scheme codans-cli` build
  both succeeded. The subsequent app test build includes the final lint fix.
- `xcodebuild test -workspace codans.xcworkspace -scheme Codans -configuration
  Debug` with `-only-testing:CodansTests/<suite>` for AgentKickoffEchoTests,
  WorkflowDefinitionV2Tests, WorkflowServiceV2Tests, WorkflowRouterV2Tests,
  WorkflowLaunchProfileV2Tests, WorkflowEndpointIdentityV2Tests,
  HandoffHandlersTests and HandoffFeatureTests passed: 49 tests in 8 suites.
- The same test command with `-scheme CodansCore` and
  `-only-testing:CodansCoreTests/<suite>` for IPCEnvelopeCodableTests,
  WireTypeCodableTests, IPCErrorCodableTests, FramingTests, HandoffBriefingTests,
  HandoffCoordinatorTests, HandoffKickoffTests, HandoffLayoutTests,
  HandoffPlacementTests, HandoffStoreTests and MarkdownDocumentNormalizerTests
  passed: 58 tests in 11 suites. IPC tests belong to CodansCoreTests;
  the CodansIPC scheme has no test target.
- The primary agent restarted the final Debug app and verified that Legacy Runs
  is absent and the existing OMP workflow history still opens with all five
  nodes Completed. It also checked the bundled CLI's `workflow --help`: only
  `list`, `status`, `claim`, `deliver` and `cancel` remain, with updated overview
  text and no template-based create command.
- Build, lint and test logs are under `/tmp/codans-workflow-v2-build/remove-legacy-*.log`;
  app and Core test result bundles are `remove-legacy-app-tests.xcresult` and
  `remove-legacy-core-tests.xcresult` in the same directory.

### Pi collapsed paste submission

Reproduce Pi 0.85.1's lowercase `[paste #N +M lines]` composer. Recognize the
new paste only inside the editor borders after an empty pre-send composer, and
reject existing drafts or history-only markers. Add regression fixtures for
Pi and retain OMP/Claude detection. Verify a real Pi receiver through GUI, then
commit the fix without submitting the user's uncertain existing assignment.

### Terminal-first launch and split history

Starting a run closes the parameter form and keeps the terminal visible, without
automatically opening history or current-run details. History keeps the run list
and selected detail side by side. Run and node statuses include a spinner while
running and colored symbols for waiting, completion, failure and interruption.
Verify launch without an automatic panel, persistent left selection, and actual
Pi submission/completion through the GUI.

- Pi receiver case `8B13B9BA-EAF1-412A-8FB5-111F4DD5CA8E` completed all four
  Handoff-from-Briefing nodes through GUI launch. Pi 0.85.1 on the configured
  DeepSeek profile read the packet, claimed its allocated attempt and submitted
  an accepted receipt without manual Return or synthetic test-driver delivery.
- Decision case `B4D69690-719F-4AF9-9C4B-92FBF3F12029` stayed in the terminal on
  launch; manual history opening showed the orange waiting indicator, and GUI
  submission changed it to green Completed. The list remained visible while
  switching between the Pi and OMP runs.
- Build and focused lint passed. 18 tests in AgentKickoffEcho, WorkflowServiceV2,
  WorkflowRouterV2 and WorkflowLaunchProfileV2 passed (`pi-history-tests.xcresult`
  under `/tmp/codans-workflow-v2-build`). The user's existing Pi paste was left
  untouched; the failed assignment was not silently resubmitted.
- Final regression (`pi-history-final-tests.xcresult`) passed the same 18 tests,
  including a non-first Pi paste marker. Final `pi-history-opaque-build.log`
  reports BUILD SUCCEEDED. GUI restart confirmed both cases remain Completed;
  the two-column popover opens to the left with an opaque system background so
  terminal text cannot wash out state indicators or cover the detail content.
