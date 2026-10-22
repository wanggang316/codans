# Command Queue Overlay

## Agreed behavior

- Command-L opens the existing command composer. The composer no longer lists queued commands.
- The pane menu displays the resolved shortcut in gray, aligned right, with space between symbols.
- Queued commands float at the top of their pane without reserving terminal space. Use the pane menu material.
- Show up to three commands initially. Show More expands the list; Show Less collapses it. Use pages when the expanded list exceeds the pane height. Do not scroll.
- Keep command summaries, timing, full-text tooltips, removal, and Clear All.
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
- App tests could not run: the existing generated dependency projects target unsupported macOS versions. Retrying with a command-line deployment target override reached a missing `Yams` dependency in the generated project.
- Live rendering, focus behavior, and keyboard delivery still require validation in a working app build.

The overlay falls back to the queue badge when a pane is too short for one row and its controls. Visibility uses scene storage keyed by pane ID, so view remounts and new commands do not reset it.
