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
