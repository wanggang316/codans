import ComposableArchitecture
import SwiftUI
import TouchCodeCore

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
  @Environment(SettingsStore.self) private var settingsStore

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
    // Primary is whichever script the user has placed at index 0
    // in the Settings → Project Scripts list. Drag-to-reorder is
    // the only knob the user has — preferring `.run` kind over
    // position would silently undo their manual reorder.
    let primary = scripts.first
    let primaryName = primary?.displayName ?? "Run"
    let primaryIcon = primary?.resolvedSystemImage ?? ScriptKind.run.defaultSystemImage
    let primaryTint = ScriptTintColorPalette.color(for: primary?.resolvedTintColor ?? .green)
    let primaryHelp = primary == nil ? "Manage Scripts…" : "Run \(primaryName)"

    Menu {
      caretMenu(scripts: scripts)
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
          .accessibilityHidden(true)
        Text(primaryName).lineLimit(1)
      }
    } primaryAction: {
      if let script = primary {
        store.send(.runScriptTapped(scriptID: script.id))
      } else {
        store.send(.manageScriptsTapped(projectID: projectID))
      }
    }
    .menuIndicator(.visible)
    .accessibilityLabel(primaryName)
    .help(primaryHelp)
    // Force Menu rebuild when scripts mutate. The signature folds id +
    // displayName + icon + tint + ORDER so add / edit / delete /
    // reorder all invalidate. Without this, NSMenu caches its items
    // across open cycles and Settings-side edits don't reflect here.
    .id(Self.identitySignature(of: scripts))
  }

  // MARK: - Caret menu

  @ViewBuilder
  private func caretMenu(scripts: [ScriptDefinition]) -> some View {
    ForEach(scripts) { script in
      menuButton(for: script)
    }
    if !scripts.isEmpty {
      Divider()
    }
    Button {
      store.send(.manageScriptsTapped(projectID: projectID))
    } label: {
      Label("Manage Scripts…", systemImage: "gearshape")
    }
  }

  /// One menu item. When the script carries a valid keyboard chord,
  /// `.keyboardShortcut(_:modifiers:)` registers it globally for the
  /// owning window — pressing the chord fires the same dispatch path
  /// as a manual menu pick, and macOS renders the chord in the menu
  /// item's trailing column automatically. Conversion from the
  /// stored `ShortcutBinding` to SwiftUI's KeyEquivalent +
  /// EventModifiers goes through `ShortcutDisplay`, the same helper
  /// the system Shortcuts pane uses.
  @ViewBuilder
  private func menuButton(for script: ScriptDefinition) -> some View {
    let button = Button {
      store.send(.runScriptTapped(scriptID: script.id))
    } label: {
      // Native menu items render their icon as a monochrome template, so the
      // tint must be baked into a non-template image (see `menuIcon`) — a
      // plain `Label(_:systemImage:)` would drop the script's colour.
      Label {
        Text(script.displayName)
      } icon: {
        ScriptTintColorPalette.menuIcon(
          systemName: script.resolvedSystemImage,
          tint: script.resolvedTintColor
        )
      }
    }
    if let chord = script.keyboardShortcut, chord.isEnabled, chord.keyCode != 0,
      let key = ShortcutDisplay.keyEquivalent(for: chord.keyCode)
    {
      button.keyboardShortcut(key, modifiers: ShortcutDisplay.eventModifiers(for: chord.modifiers))
    } else {
      button
    }
  }

  /// Stable identity for `.id(_:)`. Folds every field that affects
  /// the Menu's rendered output — name + icon + tint + chord + the
  /// array's order. id alone wouldn't change on edit; including the
  /// rendered fields means a same-id, different-content edit still
  /// rebuilds (otherwise a chord change would never bind via the
  /// system menu).
  private static func identitySignature(of scripts: [ScriptDefinition]) -> String {
    scripts
      .map { script -> String in
        let chord =
          script.keyboardShortcut.map { ShortcutDisplay.chord(for: $0) } ?? ""
        return
          "\(script.id)|\(script.displayName)|\(script.resolvedSystemImage)|\(script.resolvedTintColor.rawValue)|\(chord)"
      }
      .joined(separator: "·")
  }
}
