# HAN-162: Agents View presentation

## Scope

- Hide the panel, its reserved sidebar space, and its toggle when the catalog has no projects. Preserve the saved open preference and ignore project filtering when deciding availability.
- Keep the empty-state invitation without a decorative icon.
- Display the pane's live OSC activity title inside an already-open summary card, independently of runtime state and row ordering.

## Implementation

1. Share an availability/visibility predicate across sidebar presentation paths.
2. Keep session metadata frozen at hover time. Observe the existing pane-title cache only in the card's activity line.
3. Reserve a constant single-line activity slot, including for empty/redundant titles. Coalesce updates over one second with a trailing delivery; cancel pending updates on dismissal.
4. Preserve deferred row focus and hover-task cancellation. Do not add terminal polling, transcript parsing, or persisted state.

## Validation

- Test title normalization, coalescing, trailing delivery, cancellation, and pane isolation.
- Run existing AgentState store, summary, and ordering tests to guard state-transition behavior.
- Check empty/nonempty/long activity text has identical card dimensions.
- Check no-project visibility, last-project removal, and filtered-empty catalogs.
- Run formatting and lint for changed Swift files; attempt an app build and targeted tests.
- Record runtime checks separately from static inspection and automated tests.

## Pi working-state follow-up

The real Pi 0.86.0 GUI exposed a separate classifier gap: its live loader is
embedded in the editor border (`── ⠋ Working ───`), while the detector only
accepted the older `Working...` text. Recognize the border/spinner shape,
including narrow layouts with no message, and retain legacy compatibility.
Keep titles display-only and preserve the existing completion hold. Verify
positive and negative classifier fixtures, store completion transitions, and
a real Pi turn in the isolated GUI test app.

Validated on 2026-09-26: 46 interpreter tests and 32 store tests passed;
targeted SwiftLint and `git diff --check` passed. In the rebuilt isolated app,
GUI input started a real Pi task that ran `sleep 20`: the Agent row displayed
`working`, then `finished` after switching to another tab, and `idle` after
clicking the completed Agent row. The production app was not operated.

## Status

Implemented and validated with an unsigned Debug app build and 62 tests across
six targeted suites. The mounted activity-view test drives real store title
events without replacing the SwiftUI root, verifies text delivery and constant
fitting size, and checks the runtime entry remains unchanged. Card sizing also
covers empty, short, redundant, and long titles with and without session data.

Changed Swift files pass strict formatting. AgentState implementation and test
files pass SwiftLint. The sidebar file still has two pre-existing
`accessibility_label_for_image` violations; linting its `HEAD` version reproduces
both, and this change introduces no additional violations. `git diff --check`
passes. No-project visibility paths were checked statically, including the
footer's optional callback and the unfiltered catalog predicate.

GUI checks in a separately identified test app (`com.gumpw.codans.han162-test`)
with isolated config, cache, and socket directories passed: first launch with no
projects hides the panel and toggle; opening a temporary folder and clicking
the toggle shows the text-only empty state; removing the last project through
its GUI menu hides the panel, toggle, and reserved space without crashing.
A 29-second window-only video records the empty state and final-project removal.
All project interactions used the GUI, not CLI/RPC state injection.

After explicit authorization, Pi ran a real read-only task in the temporary
project through GUI terminal input. The app detected its Agent row, and its tab
title changed from Thinking to Task Complete. Clicking the row focused the pane
without crashing. A separate window-only clip records this execution.

Live-agent popover updates and repeated hover/click stress remain unverified in
the full app: the GUI tool exposes no hover action, and pointer-entry attempts
using its available click/scroll operations did not open the card. This does
not establish whether the limitation is in event delivery or app behavior.
The mounted-view tests do not replace these remaining lifecycle checks.

Targeted test command (from `apps/mac`):

```bash
xcodebuild test -workspace codans.xcworkspace -scheme Codans \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/han-162-derived-data \
  -only-testing:CodansTests/AgentActivityPresentationTests \
  -only-testing:CodansTests/AgentSessionSummarySnapshotTests \
  -only-testing:CodansTests/AgentSummaryCardFormatTests \
  -only-testing:CodansTests/AgentStateStoreTests \
  -only-testing:CodansTests/AgentStateOrderCoordinatorTests \
  -only-testing:CodansTests/AgentRowOrderingTests \
  CODE_SIGNING_ALLOWED=NO
```
