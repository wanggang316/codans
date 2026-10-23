# Command Queue Overlay

## Agreed behavior

- Command-L opens the command composer. It uses the New Agent grouped form style and closes after a nonempty command is sent or queued. The composer does not list queued commands.
- Schedule controls use one row above the composer actions only in Schedule mode. The editor gives up the same height while that row is visible, so other modes have no blank control row and the sheet height stays constant. Repeat uses a compact checkbox; interval controls appear only when enabled.
- The file picker can select multiple files. Append their absolute paths to the draft using shared POSIX single-quote escaping; selection alone does not send.
- The pane menu displays the resolved shortcut in gray, aligned right, with space between symbols.
- Queued commands float at the top of their pane without reserving terminal space. Use the pane menu material.
- Show up to three commands initially. Show More expands the list; Show Less collapses it. Use pages when the expanded list exceeds the pane height. Do not scroll.
- Keep command summaries, timing, full-text tooltips, removal, and Clear All. Panel dismissal and row removal use 28-point square hit areas with hover and pressed feedback.
- Hide collapses the panel into the existing queue button below the pane menu button. Use the accent color and show the count. Clicking that button restores the panel.
- Visibility belongs to each pane. New commands do not override a hidden panel. An empty queue has no panel or queue button.

## Implementation

1. Update the shortcut registry and menu hint.
2. Move the list into pane chrome. Keep queue data in the live catalog and visibility in scene storage keyed by pane ID.
3. Bound pagination by available height and clamp the page when commands drain or the pane resizes.
4. Validate pagination boundaries, shortcut defaults, formatting, and the app build where the environment permits.

## Validation

- Passed: four pagination tests and three existing shortcut schema audit tests in an isolated Swift package using the repository sources.
- Passed: SwiftLint on all changed Swift files; `git diff --check`.
- Passed: SwiftUI type checking for the overlay with temporary dependency substitutes. This checks SwiftUI API usage, not application integration.
- Full `make mac-check` encountered existing formatting/lint conflicts and an unrelated sidebar accessibility violation. Unrelated formatter edits were removed.
- Regenerating the workspace with `make mac-generate` resolved the stale deployment targets and missing Yams integration. The app now builds; 17 selected app tests pass (queue submission, pagination, pane HUD rendering, and parent-driven composer dismissal).
- The file selection follow-up passes all 14 CommandQueueFeature tests, including multiple paths, quote escaping, Unicode paths, preserved whitespace, and empty selections. Changed-file lint and `git diff --check` pass.
- Schedule layout was checked with native offscreen renders in light and dark appearances, including Repeat enabled and disabled. The final UI change passes the app build and changed-file lint.
- Live interaction, full composer appearance, and keyboard delivery have not been manually verified.

The overlay falls back to the queue badge when a pane is too short for one row and its controls. Visibility uses scene storage keyed by pane ID, so view remounts and new commands do not reset it.
