# Execution Plan: App Appearance & Terminal Theme

**Design Doc:** `docs/design-docs/app-appearance.md`

## Summary

Implement light / dark / system appearance picker, persisted to Settings → General. Add a new Settings → Terminal pane where users select light and dark terminal palettes from Ghostty's catalog, persisted to `~/.config/ghostty/config`. Both layers sync to live Ghostty surfaces immediately.

**Observable outcome:** User toggles Settings → General → Appearance from System to Dark; all windows (main, Settings, any sheets) visually switch to dark chrome and Ghostty renders the user-chosen dark palette. Changes to Settings → Terminal theme take effect in live terminals without restart.

## Orientation

This feature spans three integration points:

1. **Settings UI & persistence** — the existing `SettingsStore` infrastructure (codans's own `settings.json`) handles appearance preference, and a new `GhosttyConfigFile` reader/writer handles terminal theme selection in `~/.config/ghostty/config`.
2. **SwiftUI + AppKit rendering** — app chrome is driven by SwiftUI's `.preferredColorScheme` + AppKit's `NSApp.appearance` (dual-path to reach both native SwiftUI views and AppKit-hosted Ghostty surfaces).
3. **Ghostty runtime** — two entry points: `ghostty_app_set_color_scheme` (instant, in-memory, tells Ghostty which palette to render) and `ghostty_app_update_config` (triggered after config-file edits, re-parses and reloads).

Key files to read before starting:
- `docs/design-docs/app-appearance.md` — design decisions, alternatives considered, risks, and rationale
- `apps/mac/codans/App/Features/Settings/SettingsGeneralView.swift` — existing appearance picker (inert today)
- `apps/mac/codans/Runtime/Ghostty/GhosttyRuntime.swift` — app-level Ghostty façade (will gain two methods)
- `apps/mac/codans/App/Features/Settings/SettingsSection.swift` — enum of settings sidebar rows (will gain `.terminal` case)
- `CodansCore/Settings/GeneralSettings.swift` — model for General settings (appearance already present)

## Interfaces & Dependencies

**New types to define:**

- `AppearancePreference` (existing enum) extends with:
  - `var colorScheme: ColorScheme?` — computed, returns `.light` / `.dark` / `nil` (system)
  - `var appearance: NSAppearance?` — computed, returns `.aqua` / `.darkAqua` / `nil` (system)

- `AppAppearanceView<Content: View>` — wraps each scene's content; reads `settingsStore.settings.general.appearance` and applies both `.preferredColorScheme` and an `NSViewRepresentable` background.

- `WindowAppearanceSetter` — `NSViewRepresentable` + inner `AppearanceApplyingView: NSView` that assigns `NSApp.appearance` and walks `NSApp.windows` on `viewDidMoveToWindow`.

- `GhosttyColorSchemeSyncView<Content: View>` — wraps the terminal-hosting subtree; reads `@Environment(\.colorScheme)` and forwards changes to `GhosttyRuntime.setColorScheme(_:)`.

- `GhosttyTerminalSettings` — struct holding current theme names + list of available light/dark themes from catalog + config file path.

- `GhosttyTerminalSettingsDraft` — struct holding user-selected light/dark theme names (nil = unset).

- `GhosttyConfigFile` — reader/writer for `~/.config/ghostty/config`, manages the `theme = light:X,dark:Y` line, preserves other content byte-for-byte.

- `GhosttyThemeCatalog` — enumerates Ghostty's bundled themes and classifies by luminance (light vs dark).

- `GhosttyTerminalSettingsClient` — TCA dependency injecting closures `load() async throws` and `apply(GhosttyTerminalSettingsDraft) async throws`.

- `SettingsTerminalFeature` — TCA reducer managing load / selection / apply state for the Terminal pane.

**Extended types:**

- `GhosttyRuntime.setColorScheme(_ scheme: ColorScheme)` — calls `ghostty_app_set_color_scheme` and per-surface `ghostty_surface_set_color_scheme`.

- `GhosttyRuntime.reloadAppConfig()` — rebuilds and reapplies `ghostty_config_t` from disk, triggered by `.ghosttyRuntimeReloadRequested` notification.

- `SettingsSection` — adds `.terminal` case.

- `SettingsWindowView` — handles `.terminal` case in the sidebar / detail routing.

**Dependencies imported:**
- `GhosttyKit` (already available) — provides `ghostty_app_set_color_scheme`, `ghostty_surface_set_color_scheme`, etc.
- `AppKit` (for `NSAppearance`, `NSView`, `NSApp`)
- `SwiftUI` (for `ColorScheme`, `View`, `@Environment`, `preferredColorScheme`)
- `ComposableArchitecture` (for TCA types used in `SettingsTerminalFeature`)

**Notifications:**
- `Notification.Name.ghosttyRuntimeReloadRequested` — posted after Ghostty config-file write; `GhosttyRuntime` listens and calls `reloadAppConfig()`.

## Plan of Work

### Milestone 1: Extend `AppearancePreference` & wire app-level appearance

**Goal:** Changing Settings → General → Appearance updates all windows' chrome immediately.

**Tasks:**

1. **Extend `AppearancePreference` with projections** (`app/Theme/AppearancePreference+UI.swift`, ~10 LOC)
   - Add `ColorScheme?` and `NSAppearance?` computed properties.
   - Test: assert `.system → nil`, `.light → .light / .aqua`, `.dark → .dark / .darkAqua`.

2. **Create `AppAppearanceView<Content>` wrapper** (`app/Theme/AppAppearanceView.swift`, ~30 LOC)
   - Reads `@Environment(SettingsStore.self)`.
   - Applies `.preferredColorScheme(preference.colorScheme)` to content.
   - Adds `.background { WindowAppearanceSetter(...) }`.

3. **Create `WindowAppearanceSetter` NSViewRepresentable** (`app/Theme/WindowAppearanceSetter.swift`, ~50 LOC)
   - Inner `AppearanceApplyingView: NSView` with `viewDidMoveToWindow` → `applyAppearance()`.
   - `applyAppearance()` assigns `NSApp.appearance` and iterates `NSApp.windows`, forcing layout/shadow refresh.
   - Track preference via `didSet` to re-apply on change.

4. **Create `AppearanceDiagnostics` logger** (`app/Theme/AppearanceDiagnostics.swift`, ~30 LOC)
   - Simple `os_log` wrapper or `print` to `os_log`.
   - Log on: user mode change, `viewDidMoveToWindow`, per-window application, Ghostty sync.

5. **Wire `AppAppearanceView` into both scenes** (modify `app/CodansApp.swift`)
   - Wrap `WindowGroup { ... }` content: `AppAppearanceView { ContentView(...) }`.
   - Wrap `Window("Settings", ...) { ... }` content: `AppAppearanceView { SettingsWindowView(...) }`.

6. **Remove "preview only" text** (modify `app/Features/Settings/Panes/SettingsGeneralView.swift`, ~2 LOC)
   - Remove caption "Preview — themes will ship in a later release."
   - Drop docstring mention of "preview only" from `AppearancePreference.swift`.

**Verification:**
- Launch app, toggle Settings → General → Appearance between Light / Dark / System.
- Observe main window chrome (title bar, scrollbars) re-render immediately.
- Observe Settings window chrome re-render immediately.
- Open a new sheet (e.g., Space Manager); it inherits the current appearance.
- In System mode, toggle system Appearance in macOS System Settings; app follows within 1 frame.
- Check `os_log` (Console.app) for diagnostics: should see "app appearance", "window appearance applied" events.

---

### Milestone 2: Extend `GhosttyRuntime` for runtime color-scheme sync

**Goal:** Ghostty surfaces immediately render the correct palette (light or dark) when app appearance changes.

**Tasks:**

1. **Add `setColorScheme(_:)` to `GhosttyRuntime`** (modify `Runtime/Ghostty/GhosttyRuntime.swift`, ~30 LOC)
   ```swift
   func setColorScheme(_ scheme: ColorScheme) {
     guard let app else { return }
     let ghosttyScheme: ghostty_color_scheme_e = scheme == .dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
     lastColorScheme = ghosttyScheme  // cache for newly registered surfaces
     ghostty_app_set_color_scheme(app, ghosttyScheme)
     for ref in surfaceRefs where ref.isValid {
       ghostty_surface_set_color_scheme(ref.surface, ghosttyScheme)
       ghostty_surface_refresh(ref.surface)
     }
   }
   ```
   - Cache `lastColorScheme` so new surfaces inherit it (see Risk 5 in design doc).

2. **Add `reloadAppConfig()` to `GhosttyRuntime`** (modify `Runtime/Ghostty/GhosttyRuntime.swift`, ~15 LOC)
   ```swift
   func reloadAppConfig() {
     guard let app else { return }
     guard let config = Self.loadConfig(at: configPath, includeCLIArgs: includeCLIArgs) else { return }
     ghostty_app_update_config(app, config)
     ghostty_config_free(config)
   }
   ```

3. **Register notification listener in `GhosttyRuntime.init`** (modify `Runtime/Ghostty/GhosttyRuntime.swift`, ~8 LOC)
   ```swift
   NotificationCenter.default.addObserver(
     forName: NSNotification.Name("ghosttyRuntimeReloadRequested"),
     object: nil,
     queue: .main
   ) { [weak self] _ in self?.reloadAppConfig() }
   ```

4. **Create `GhosttyColorSchemeSyncView<Content>`** (`app/Theme/GhosttyColorSchemeSyncView.swift`, ~20 LOC)
   - Wraps terminal-hosting subtree (in `ContentView` or where panes render).
   - Reads `@Environment(\.colorScheme)` and calls `ghostty.setColorScheme(_:)` on change.
   - Include `initial: true` so new surfaces get the scheme on mount.

5. **Wire `GhosttyColorSchemeSyncView` into `ContentView`** (modify `app/ContentView.swift`)
   - Wrap the `PaneHostView` or similar where Ghostty surfaces render.

**Verification:**
- Launch app, open a terminal pane (Ghostty surface).
- Toggle Settings → General → Appearance.
- Observe Ghostty palette (foreground, background, ANSI colors) flips immediately.
- Toggle system macOS Appearance while in System mode; Ghostty follows without user action.
- Check `os_log`: should see "ghostty sync reason=colorSchemeChanged / initialColorScheme".

---

### Milestone 3: Implement `GhosttyConfigFile` reader / writer

**Goal:** Settings → Terminal pane can read and write Ghostty theme selection to the user's config file.

**Tasks:**

1. **Create `GhosttyThemeCatalog`** (`Runtime/Ghostty/GhosttyThemeCatalog.swift`, ~80 LOC)
   - Enumerate `$XDG_CONFIG_HOME/ghostty/themes` and Ghostty's resource bundle themes.
   - Parse theme files; extract `background = ...` line and classify by luminance (Y > 0.5 = light).
   - Return `struct { light: [String], dark: [String] }` sorted alphabetically.
   - Handle missing directories gracefully (return empty arrays).

2. **Create `GhosttyConfigFile` struct** (`Runtime/Ghostty/GhosttyConfigFile.swift`, ~200 LOC)
   - `load() throws → GhosttyTerminalSettings`: read config file, parse managed keys, enumerate themes.
   - `apply(GhosttyTerminalSettingsDraft) throws`: write managed region atomically.
   - Managed-keys strategy: filter lines with known keys, preserve others, insert canonical managed block at first removed key index (or end).
   - Write to temp file, let Ghostty's parser validate it, then `replaceItem` atomic swap.
   - On write, post `.ghosttyRuntimeReloadRequested` notification.
   - Handle `ensureConfigFile()` — create `~/.config/ghostty/config` if missing.

3. **Create `GhosttyTerminalSettingsClient` dependency** (`app/Clients/GhosttyTerminalSettingsClient.swift`, ~50 LOC)
   - TCA dependency wrapping `GhosttyConfigFile.load` and `apply` closures.
   - `liveValue` bridges to real file I/O on `MainActor`.
   - `testValue` serves fixture data in-memory.

4. **Add `.ghosttyRuntimeReloadRequested` Notification.Name** (modify `Runtime/Ghostty/GhosttyRuntime.swift` or shared Support)
   ```swift
   extension Notification.Name {
     static let ghosttyRuntimeReloadRequested = Notification.Name("ghosttyRuntimeReloadRequested")
   }
   ```

**Verification:**
- Manually edit `~/.config/ghostty/config` to set a theme (e.g., `theme = light:Zenbones Light,dark:Zenbones Dark`).
- Programmatically call `GhosttyConfigFile().load()`.
- Assert returned `GhosttyTerminalSettings` has correct light/dark theme names and catalog populated.
- Call `GhosttyConfigFile().apply(GhosttyTerminalSettingsDraft(lightTheme: "NewLight", darkTheme: "NewDark"))`.
- Read `~/.config/ghostty/config` directly; assert theme line updated and other content unchanged.
- Assert notification was posted.

---

### Milestone 4: Implement Settings → Terminal pane

**Goal:** User can pick light and dark terminal palettes in Settings; changes persist to Ghostty config and take effect in live terminals.

**Tasks:**

1. **Add `.terminal` case to `SettingsSection`** (modify `app/Features/Settings/SettingsSection.swift`, ~2 LOC)
   ```swift
   public enum SettingsSection: Hashable, Sendable {
     case general, notifications, developer, shortcuts, updates, about, terminal
     case repositoryGeneral(ProjectID), repositoryHooks(ProjectID)
   }
   
   public static let globals: [SettingsSection] = [
     .general, .notifications, .developer, .shortcuts, .updates, .about, .terminal,
   ]
   ```

2. **Create `SettingsTerminalFeature` TCA reducer** (`app/Features/Settings/SettingsTerminalFeature.swift`, ~100 LOC)
   ```swift
   struct SettingsTerminalFeature: Reducer {
     struct State: Equatable {
       var snapshot: GhosttyTerminalSettings?
       var isLoading = false
       var isApplying = false
       var errorMessage: String?
       var warningMessage: String?
     }
     
     enum Action {
       case onAppear
       case loadResult(TaskResult<GhosttyTerminalSettings>)
       case lightThemeSelected(String?)
       case darkThemeSelected(String?)
       case applyResult(TaskResult<GhosttyTerminalSettings>)
     }
     
     @Dependency(\.ghosttyTerminalSettingsClient) var client
     
     var body: some Reducer<State, Action> {
       Reduce { state, action in ... }
     }
   }
   ```

3. **Create `SettingsTerminalView` UI** (`app/Features/Settings/Panes/SettingsTerminalView.swift`, ~120 LOC)
   - Form with LabeledContent("Light/Dark Theme") containing two Picker side by side.
   - Each Picker shows theme name, "Select Theme" placeholder if nil.
   - Display config file path below (read-only).
   - Show warning / error messages if present.
   - Disable pickers while `isLoading || isApplying`.
   - Footer: "codans reads and writes your Ghostty config, so changes here stay in sync with Ghostty itself."

4. **Wire Terminal pane into `SettingsWindowView`** (modify `app/Features/Settings/SettingsWindowView.swift`)
   - Add sidebar row for `.terminal` (label: "Terminal").
   - Switch in detail view: `case .terminal: SettingsTerminalView(store: ...)`.
   - Inject `GhosttyTerminalSettingsClient.liveValue` into the reducer's dependencies.

5. **Inject `GhosttyTerminalSettingsClient` dependency in `AppState.bringUp()`** (modify `app/CodansApp.swift`)
   - Set `$0.ghosttyTerminalSettingsClient = .appLiveValue` in `SettingsWindowFeature` dependencies.

**Verification:**
- Launch app, open Settings → Terminal.
- Verify config file path is displayed and matches `~/.config/ghostty/config`.
- Verify light and dark theme lists are populated (non-empty if Ghostty has themes).
- Select a different light theme; verify Settings shows loading indicator briefly, then settles.
- Check `~/.config/ghostty/config`; assert theme line updated.
- Open Ghostty pane in main window; verify palette visually changes to the selected light theme.
- Toggle app appearance to Dark; verify palette switches to the selected dark theme.
- Manually edit `~/.config/ghostty/config` to corrupt the theme line; re-open Settings → Terminal and select a new theme.
- Assert error message appears (e.g., "Config file had parse issues — reverted to previous state").
- Assert the real `~/.config/ghostty/config` file was not overwritten (validation passed).

---

### Milestone 5: Integration tests & polish

**Goal:** Feature works end-to-end; app appearance and terminal theme are in sync.

**Tasks:**

1. **Write unit tests for `AppearancePreference` projections**
   - Test `ColorScheme?` and `NSAppearance?` mapping for all three cases.
   - File: `apps/mac/CodansCoreTests/AppearancePreferenceTests.swift`.

2. **Write unit tests for `GhosttyConfigFile`**
   - Test `updatedContents(from:settings:)` pure string transformation.
   - Test cases: empty file, unrelated content, existing managed lines, trailing newlines, comments mixed with managed keys.
   - File: `apps/mac/codans/Tests/GhosttyConfigFileTests.swift`.

3. **Write unit tests for `GhosttyThemeCatalog` classification**
   - Test `background = #RRGGBB` parsing and luminance calculation.
   - Test light vs dark classification boundary.

4. **Write TCA snapshot tests for `SettingsTerminalFeature`**
   - Test load → snapshot populated.
   - Test selection action → apply action → result.
   - Test error path (invalid theme) → error message shown, state unchanged.

5. **Manual end-to-end walkthroughs** (not automated, just documented checklist)
   - Fresh install: Settings → General → Appearance picker works, switches chrome + palette.
   - System mode: toggle macOS Appearance; app follows.
   - Settings → Terminal: pick new themes, verify live Ghostty palette changes.
   - Concurrent edit: user in text editor changes `~/.config/ghostty/config` while `SettingsTerminalView` is open; next theme selection in the UI should succeed (our atomic write + validation wins cleanly).

6. **Code review checklist**
   - Verify no hardcoded paths (use `FileManager.homeDirectoryForCurrentUser`).
   - Verify notification listener is deregistered on `GhosttyRuntime` deinit.
   - Verify temp file in `apply()` is cleaned up even on error.
   - Verify all new `@MainActor` annotations are appropriate.

**Verification:**
- All unit tests pass.
- Integration checklist completed; document findings in commit message.

---

## Risks & Mitigations

1. **libghostty runtime scheme API behavior** — `ghostty_app_set_color_scheme` + `ghostty_surface_set_color_scheme` may not produce visible palette change without config reload.
   - **Mitigation:** Prototype in Milestone 2, Task 1. If visible change is insufficient, add `ghostty_surface_refresh` or fallback to re-parsing config on every scheme change.

2. **Ghostty theme catalog location / format** — themes directory path or classification heuristic may not match reality.
   - **Mitigation:** Validate in Milestone 3, Task 1 against a real Ghostty install. Refine heuristic if necessary; log discovered themes in diagnostics.

3. **Config file edge cases** — user's file has unexpected shape (includes, comments, multi-line values).
   - **Mitigation:** Managed-keys strategy is line-level only; non-managed lines preserved verbatim. Temp-file validation in Milestone 3 catches unparseable results before overwriting the real file.

4. **AppKit + SwiftUI path drift** — windows inconsistently themed.
   - **Mitigation:** Both paths driven from single enum; diagnostics log records applied state per window. Manual visual inspection in Milestone 5.

5. **Concurrent Ghostty config edits** — race between our write and user's text editor.
   - **Mitigation:** Atomic `replaceItem` swap guarantees consistent file state to any reader. Last-write-wins is filesystem standard; acceptable for rarely-edited config.

## Success Criteria

- [ ] Changing Settings → General → Appearance switches all windows' chrome (SwiftUI + AppKit hosted surfaces) immediately.
- [ ] In System mode, toggling macOS Appearance cause app to follow within one frame (no user action required).
- [ ] Ghostty surfaces render the correct palette (light or dark) matching the app appearance.
- [ ] Settings → Terminal pane presents light/dark theme pickers populated from Ghostty's catalog.
- [ ] Selecting a theme writes to `~/.config/ghostty/config` with `theme = light:X,dark:Y` line.
- [ ] Existing lines in config file are preserved byte-for-byte.
- [ ] Theme change in Ghostty palette is visible in live terminals without restart.
- [ ] Opening a new Ghostty surface after a theme change inherits the current scheme.
- [ ] Config file validation prevents corrupted writes; error message shown to user if validation fails; real file untouched.
- [ ] All unit tests pass; manual integration checklist completed.
- [ ] Documentation in `docs/design-docs/app-appearance.md` matches implementation.
