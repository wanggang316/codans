import ComposableArchitecture
import SwiftUI
import CodansCore

/// Native toolbar split button: primary action runs the Project's
/// first script (whichever the user has dragged to index 0 in
/// Settings → Project Scripts); the chevron half lists every script
/// plus a "Manage Scripts…" footer. Empty-state: primary click and
/// every menu item route to "Manage Scripts" so users land in a
/// place where they can create one. Uses
/// `Menu(content:label:primaryAction:)` so macOS renders the native
/// split-button chrome.
///
/// Both halves dispatch through `WorktreeHeaderFeature.delegate` so
/// `RootFeature` owns the `HierarchyClient.runScript` effect.
struct HeaderRunScriptSplitButton: View {
  @Bindable var store: StoreOf<WorktreeHeaderFeature>
  /// Project whose script list the dropdown enumerates. The active
  /// Worktree is intentionally NOT stored on this view: the chord +
  /// menu dispatch goes through `RootFeature` which resolves the
  /// target Worktree from `state.selection` at handle-time, sidestepping
  /// stale NSMenuItem closure captures on worktree switch.
  let projectID: ProjectID
  /// Selected Worktree, used *only* to read the live Run/Stop state for this
  /// view (`HierarchyManager.isScriptRunning`). Dispatch still routes
  /// scriptID-only through `RootFeature`, which re-resolves the worktree from
  /// `state.selection` at handle-time — so this read-only capture cannot fire
  /// a script against the wrong worktree. The view is rebuilt per resolved
  /// address, so the value tracks the live selection.
  let worktreeID: WorktreeID
  @Environment(SettingsStore.self) private var settingsStore
  /// Live busy state for the Run/Stop toggle. `@Observable`, so reads in
  /// `body` re-render the button when a run pane starts/stops executing —
  /// same source the tab busy spinner reads.
  @Environment(HierarchyManager.self) private var hierarchyManager

  var body: some View {
    // Read scripts once, here, inside body. Two load-bearing reasons:
    // 1. Swift Observation only tracks reads that happen during a
    //    body re-evaluation. Reading via a computed-property getter
    //    that is called from a `label:` closure CAN escape the
    //    observation context inside a toolbar Menu — body would not
    //    re-render when SettingsStore mutates.
    // 2. .id(_:) below uses these values as the Menu's identity. The
    //    scripts ARRAY and ORDER both contribute, so any add / edit /
    //    delete / reorder forces SwiftUI to rebuild the Menu (and the
    //    underlying NSMenu, which otherwise caches its items across
    //    open / close cycles).
    let scripts = settingsStore.settings.projects[projectID]?.scripts ?? []
    // Global commands (`general.globalScripts`) surface in the same dropdown
    // under their own section, below the Project commands. Read here in body
    // for the same Observation + `.id(_:)` reasons as the project list.
    let globalScripts = settingsStore.settings.general.globalScripts
    // Primary is whichever script the user has placed at index 0
    // in the Settings → Project Scripts list. Drag-to-reorder is
    // the only knob the user has — preferring `.run` kind over
    // position would silently undo their manual reorder.
    let primary = scripts.first
    let primaryName = primary?.displayName ?? "Run"
    // Run/Stop toggle: while the primary script's dedicated pane is executing
    // a foreground command, the button becomes a red Stop that interrupts it
    // (Ctrl-C) instead of launching another run.
    let isRunning =
      primary.map {
        hierarchyManager.isScriptRunning(worktreeID: worktreeID, scriptID: $0.id)
      } ?? false
    let primaryIcon =
      isRunning ? "stop.fill" : (primary?.resolvedSystemImage ?? ScriptKind.run.defaultSystemImage)
    let primaryTint =
      isRunning
      ? ScriptTintColorPalette.color(for: .red)
      : ScriptTintColorPalette.color(for: primary?.resolvedTintColor ?? .green)
    let primaryHelp =
      primary == nil
      ? "Manage Scripts…" : (isRunning ? "Stop \(primaryName)" : "Run \(primaryName)")
    // While ⌘ is held the button surfaces its chord (the macOS menu
    // convention). Idle → the primary script's configured shortcut; running →
    // the fixed ⌘. stop chord. `commandKeyHint` gates the actual display on ⌘.
    let primaryChord: String? =
      isRunning
      ? "⌘."
      : primary?.keyboardShortcut.flatMap {
        $0.isEnabled && $0.keyCode != 0 ? ShortcutDisplay.chord(for: $0) : nil
      }
    // Per-script running flags, read in body so Observation re-renders this
    // view when a run pane starts/stops. Folded into the Menu `.id` below so
    // the cached NSMenu's items flip Run⇄Stop instead of staying stale.
    let runningSignature =
      (scripts + globalScripts)
      .map { hierarchyManager.isScriptRunning(worktreeID: worktreeID, scriptID: $0.id) ? "1" : "0" }
      .joined()

    Menu {
      caretMenu(scripts: scripts, globalScripts: globalScripts)
    } label: {
      // Manual HStack — `Label(_:systemImage:)` collapses to a
      // single-colour template via the toolbar's default LabelStyle,
      // killing the script's tint colour. Driving the icon as a
      // standalone Image lets `.foregroundStyle(primaryTint)` survive
      // toolbar reduction. `.symbolRenderingMode(.palette)` defends
      // against SwiftUI fallbacks that would otherwise re-monochrome
      // the glyph at render time.
      HStack(spacing: 6) {
        Image(systemName: primaryIcon)
          .symbolRenderingMode(.palette)
          .foregroundStyle(primaryTint)
          // play.fill (triangle) and stop.fill (square) have different glyph
          // widths, so a bare swap made the button reflow on every toggle.
          // A fixed square footprint keeps the icon column constant and the
          // `.replace` transition cross-fades the swap instead of popping.
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
          // Chord rides right after the icon (left of the chevron), matching
          // the sibling Open button — anchoring on the trailing edge would let
          // it merge with the system menu indicator.
          .commandKeyHint(chord: primaryChord)
        Text(isRunning ? "Stop" : primaryName).lineLimit(1)
      }
    } primaryAction: {
      if let script = primary {
        if isRunning {
          store.send(.stopScriptTapped(scriptID: script.id))
        } else {
          store.send(.runScriptTapped(scriptID: script.id))
        }
      } else {
        store.send(.manageScriptsTapped(projectID: projectID))
      }
    }
    .menuIndicator(.visible)
    .accessibilityLabel(isRunning ? "Stop \(primaryName)" : primaryName)
    .help(primaryHelp)
    // Force Menu rebuild when scripts mutate. The signature folds id +
    // displayName + icon + tint + ORDER so add / edit / delete /
    // reorder all invalidate, across BOTH the project and global lists.
    // Without this, NSMenu caches its items across open cycles and
    // Settings-side edits don't reflect here.
    .id(
      Self.identitySignature(of: scripts) + "##"
        + Self.identitySignature(of: globalScripts) + "#" + runningSignature)
  }

  // MARK: - Caret menu

  /// Menu order, top to bottom: Project Commands section, Global Commands
  /// section, divider, then the two "Manage …" footers. A section is omitted
  /// when its list is empty so an empty group header never shows; the Manage
  /// footers always render so the user can reach either pane from here.
  @ViewBuilder
  private func caretMenu(
    scripts: [ScriptDefinition],
    globalScripts: [ScriptDefinition]
  ) -> some View {
    if !scripts.isEmpty {
      Section("Project") {
        ForEach(scripts) { script in
          menuButton(for: script)
        }
      }
    }
    if !globalScripts.isEmpty {
      Section("Global") {
        ForEach(globalScripts) { script in
          menuButton(for: script, isGlobal: true)
        }
      }
    }
    if !scripts.isEmpty || !globalScripts.isEmpty {
      Divider()
    }
    Button("Manage Project Commands…") {
      store.send(.manageScriptsTapped(projectID: projectID))
    }
    Button("Manage Global Commands…") {
      store.send(.manageGlobalScriptsTapped)
    }
  }

  /// One menu item. Deliberately does **not** attach the script's chord via
  /// `.keyboardShortcut(_:modifiers:)`: a keyEquivalent makes AppKit reserve a
  /// trailing accelerator column across *every* row, so the chord-less footers
  /// ("Manage … Commands…") render with a wide empty right gutter and the whole
  /// dropdown balloons far past its longest label. Dropping the in-menu chord
  /// collapses that column so the menu hugs "Manage Project Commands…" — the
  /// widest item. The chord still fires: `ProjectScriptsShortcutBindings` mounts
  /// the real responder-chain binding outside the toolbar (the in-menu binding
  /// was never the live dispatch path — it only lit up after the menu had been
  /// opened and dropped on the next `.id(_:)` rebuild).
  ///
  /// `isGlobal` switches the run dispatch between the project run path
  /// (`runScriptTapped`) and the global run path (`runGlobalScriptTapped`).
  /// Stop is shared (`stopScriptTapped`) because the run pane is keyed by
  /// (worktree, scriptID), unique across both lists.
  private func menuButton(for script: ScriptDefinition, isGlobal: Bool = false) -> some View {
    // Mirror the primary half: a running script's menu row becomes a red
    // "Stop …" that interrupts it.
    let isRunning = hierarchyManager.isScriptRunning(worktreeID: worktreeID, scriptID: script.id)
    return Button {
      if isRunning {
        store.send(.stopScriptTapped(scriptID: script.id))
      } else if isGlobal {
        store.send(.runGlobalScriptTapped(scriptID: script.id))
      } else {
        store.send(.runScriptTapped(scriptID: script.id))
      }
    } label: {
      // Native menu items render their icon as a monochrome template, so the
      // tint must be baked into a non-template image (see `menuIcon`) — a
      // plain `Label(_:systemImage:)` would drop the script's colour.
      Label {
        Text(isRunning ? "Stop \(script.displayName)" : script.displayName)
      } icon: {
        ScriptTintColorPalette.menuIcon(
          systemName: isRunning ? "stop.fill" : script.resolvedSystemImage,
          tint: isRunning ? .red : script.resolvedTintColor
        )
      }
    }
  }

  /// Stable identity for `.id(_:)`. Folds every field that affects the Menu's
  /// rendered output — name + icon + tint + the array's order. id alone
  /// wouldn't change on a same-id edit; including the rendered fields means an
  /// edit to any of them still rebuilds the cached NSMenu. The chord is
  /// intentionally absent: it no longer renders in the menu (see `menuButton`),
  /// so a chord-only change has nothing to invalidate here.
  private static func identitySignature(of scripts: [ScriptDefinition]) -> String {
    scripts
      .map { script -> String in
        "\(script.id)|\(script.displayName)|\(script.resolvedSystemImage)|\(script.resolvedTintColor.rawValue)"
      }
      .joined(separator: "·")
  }
}
