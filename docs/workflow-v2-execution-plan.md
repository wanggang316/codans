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
