# Appearance

The appearance domain decides how codans looks: light or dark, which terminal palette, which font and cursor, and how the window chrome takes its colors from the terminal. It has two inputs with different owners. The app appearance (Light, Dark, or System) is a codans setting. The terminal theme, font, cursor, and background are lines in the user's Ghostty config file, which codans shares with Ghostty itself.

## Scope and ownership

This page owns the app appearance and its single writer, the bridge from the appearance to the terminal palette, the managed lines in the Ghostty config file, the assembly of the runtime Ghostty config, and the window background and chrome tint.

Neighbor topics:

- The Settings window, `settings.json`, and `SettingsStore`: [Settings](settings.md).
- Terminal surfaces, zmx, and action routing: [Terminal runtime](terminal-runtime.md).
- Shell integration and the libghostty fork: [Pane shell integration](pane-shell-integration.md).
- The regions of the main window (sidebar, header, toolbar): [Main window](main-window.md).

## Two inputs, two paths

| Input | Stored in | Changes | Cost of a change |
|---|---|---|---|
| Appearance: `system` / `light` / `dark` | `settings.json` (`general.appearance`) | Often: each picker change, each macOS dark-mode flip in System mode | In memory, no file I/O |
| Light theme, dark theme, font, cursor, background | The Ghostty config file | Rarely: only when the user picks a value in Settings › Terminal | File write, validation, full config re-parse |

The two paths stay separate. An appearance flip only selects which of the two configured palettes Ghostty renders; it never writes the config file. The Terminal pane of Settings writes only the Ghostty config file. It keeps no state in `settings.json`, so the terminal looks the same in codans and in Ghostty.

```
 Settings › General: Appearance           Settings › Terminal: theme, font, ...
 (settings.json)                          (Ghostty config file)
        │                                          │ apply(draft)
        ▼                                          ▼
 WindowAppearanceSetter                    GhosttyConfigFile
  ├─ NSApp.appearance + each window          rewrite managed lines,
  └─ setColorScheme(light | dark) ─┐         validate, atomic swap
                                   │                │ .ghosttyRuntimeReloadRequested
                                   ▼                ▼
                     GhosttyRuntime: app + each surface
                     (scheme switch in memory | rebuild config from disk)
                                   │
                                   ▼
             live surfaces, window background, chrome tint
```

## App appearance

`WindowAppearanceSetter` is the only writer of the app appearance. `AppAppearanceView` places it at the root of each scene (the main window and the Settings window), so a window that opens later gets the current appearance when it attaches. On each change it sets `NSApp.appearance` (nil for System), then sets the appearance of every window in `NSApp.windows` and invalidates its layout and shadow.

Rules:

- Do not add `.preferredColorScheme` anywhere. It pins `NSWindow.appearance` too, so two writers fight, and its nil case does not reset a pinned window: a switch from Light or Dark back to System then stays on the old scheme. SwiftUI reads `colorScheme` from the effective appearance of the host window, so it follows the AppKit writer without help.
- In Light and Dark mode, a main window takes the appearance that matches the luminance of the terminal background, not the picker value. The toolbar and sidebar materials then match the terminal palette. In System mode a window keeps a nil appearance, so macOS dark-mode flips reach it directly.
- The Settings window always takes the picker value and the standard opaque window background. It never takes the terminal tone.

## Terminal palette follows the appearance

The `theme` line holds two palettes: `theme = light:<name>,dark:<name>`. `GhosttyRuntime.setColorScheme` tells libghostty which one to render, on the app and on each surface, and repaints the window backgrounds. This is a switch in memory, not a reload.

- The scheme comes from the picker value: Light and Dark map directly, System reads the effective appearance of the setter view. It must not come from the window appearance, because in Light and Dark mode that appearance comes from the terminal background, and the result would be a feedback loop that drops the user's choice.
- Two callers push the scheme: `viewDidChangeEffectiveAppearance` in the setter view, which also catches system flips, and `GhosttyColorSchemeSyncView` around the terminal subtree. Both skip a repeated value.
- The runtime keeps the last scheme. A surface that registers later gets it at once, so a new Pane opens with the correct palette.
- If the user sets only one theme, the app writes that theme for both sides.

## The Ghostty config file

The file is `$XDG_CONFIG_HOME/ghostty/config`, else `~/.config/ghostty/config`. It is the same file that Ghostty reads. Settings › Terminal reads and writes only this path. The pane also shows the path and opens the file in the default text editor.

**Managed keys.** codans owns six keys: `theme`, `font-family`, `font-size`, `cursor-style`, `background-opacity`, and `background-blur`. It owns no other line. A save works line by line:

1. Remove every line whose key is a managed key, wherever it is.
2. Build one line for each managed value that is set, always in the same order. A value set to Default writes no line, so Ghostty's default applies.
3. Insert these lines where the first removed line was, or at the end of the file when there was none.
4. Keep every other line byte for byte: comments, blank lines, unknown keys, `config-file` includes, and the trailing newline.
5. Write a temporary sibling file, load it through libghostty, and refuse the save on any diagnostic. The original file stays unchanged and the pane shows the error.
6. Replace the real file atomically, so a reader sees the old file or the new file, never a part. Then post `.ghosttyRuntimeReloadRequested`.

There is no marker comment around the managed lines. A line belongs to codans only because of its key.

**Hand edits of a managed key.** The pane reads the first occurrence of each managed key. The next save from the pane rewrites all managed keys from the values the pane holds: duplicate lines collapse into one, and a value in a form the pane does not model is removed. Examples: a single-name `theme = X` (the pane shows a warning before it replaces it), a numeric `background-blur`, an unknown `cursor-style`.

**Theme catalog.** The pickers list theme files from the user theme directories (`$XDG_CONFIG_HOME/ghostty/themes`, `~/.config/ghostty/themes`) and then the themes bundled with Ghostty. A user theme hides a bundled theme with the same name. A theme is light when the luminance of its `background` is above 0.5, else dark, also when it has no background. A selected theme that is not in the catalog still shows as the current value.

## Applying a change to live terminals

On `.ghosttyRuntimeReloadRequested`, the runtime builds a new config from disk and gives it to libghostty with `ghostty_app_update_config`. libghostty applies it to every live surface and returns the applied config, which the runtime keeps. The runtime then repaints the window backgrounds and posts `.ghosttyRuntimeConfigApplied`. Readers of derived values, such as the chrome tint, listen to this second notification, because the first one fires before the new config exists.

`GhosttyConfigLoader` is the only builder of a runtime config. The order is the contract, and the last value wins:

1. codans defaults (terminal padding). The user can change them.
2. The user's Ghostty files: the default files and their `config-file` includes.
3. codans overrides (the `⌘⏎` fullscreen binding is removed). The user cannot change them.
4. If `background-opacity` is below 1: the surface is forced transparent, and the window draws the tint and the blur.

## Window background and chrome

The terminal background color becomes the window background, so the translucent sidebar and toolbar materials read as the terminal tone. With `background-opacity` below 1, the window becomes non-opaque, takes the tint at that opacity, and gets the blur style of `background-blur`. In full screen the window stays opaque. The detail column also draws a weak band of the terminal color behind the toolbar and the sidebar (`ghosttyChromeTint`).

Rules:

- SwiftUI owns the titlebar and toolbar transparency: `.windowToolbarStyle(.unified)` on the main scene and `.toolbarBackground(.hidden, for: .windowToolbar)` on the Worktree detail. Do not set `titlebarAppearsTransparent` or other titlebar properties through AppKit. That fights SwiftUI's toolbar management and separates the header from the window. The runtime owns only the window background color, opacity, and blur.
- Only windows that can become key take the terminal background. Menus, tooltips, and the input-source indicator panel are also in `NSApp.windows`; an opaque background turns the indicator into a solid box over the terminal.

## Traps

- **A hand edit is lost after a pane pick.** The Terminal pane loads the file once per app run, at its first open. If the user then edits a managed key by hand, the pane does not see it, and the next pick writes the loaded values back over the edit.
- **A hand edit does not reach live terminals at once.** The runtime does not watch the file. A hand edit applies at the next reload from disk: the next save from the Terminal pane, a Ghostty `reload_config` action, or the next app start.
- **A pick seems to have no effect.** The runtime also loads the Ghostty file in `~/Library/Application Support/com.mitchellh.ghostty/` and all `config-file` includes. A managed key set there wins over the line that codans writes.
- **A broken user line blocks every save.** Validation loads the whole candidate file. Any diagnostic, also one from a line that codans did not write, refuses the save.
- **A light palette with a dark chrome, or the reverse.** In Light and Dark mode the main window chrome follows the terminal background. A theme whose background does not match its side gives the chrome the other appearance. This is by design.

## Implementation shape

`AppearancePreference` in `CodansCore/Settings/` is the saved value. Its `NSAppearance` and `ColorScheme` projections live in `App/Theme/`, so `CodansCore` stays free of AppKit. `App/Theme/` holds the scene wrapper, the single writer, the scheme sync view, and the chrome tint. `Runtime/Ghostty/` holds `GhosttyConfigFile` (the managed-key writer), `GhosttyThemeCatalog`, `GhosttyConfigLoader`, and the scheme and reload entry points on `GhosttyRuntime`. `SettingsTerminalFeature` reaches the file through `GhosttyTerminalSettingsClient`, and a fast series of picks cancels the write in flight so the last pick lands. A notification is the only link from the file writer to the runtime.
