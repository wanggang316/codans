import AppKit
import SwiftUI
import TouchCodeCore

/// Shared building blocks for every "Open in / Default editor" dropdown across the app
/// (Settings → General + Project pane and the Worktree header's Open-in split
/// button). All surfaces share one visual contract — a flat priority-
/// ordered list where each row is `icon + displayName`; no groupings, no auto-resolve
/// sentinel. Callers decide whether to prepend a semantic sentinel row (e.g. "Use
/// global default" for per-project overrides).
///
/// Scope: this file is intentionally bound to the editor-picker UI. It lives under the
/// Settings Panes directory because it is used by sibling views; extracting further
/// would pull editor-specific assumptions into a generic UI module.
enum EditorPickerRow {
  /// 16×16 glyph for an editor row. Uses Launch Services' bundled icon for bundle-backed
  /// entries and a terminal SF Symbol for the `.shellEditor` pseudo-entry. The catch-all
  /// `app.dashed` glyph handles a defensive "bundle-backed but unresolved" case that
  /// `describe()` filters out in practice.
  ///
  /// App-bundle icons are pre-resized at the AppKit level (NSImage redraw
  /// into 16×16) instead of leaning on SwiftUI `.resizable()`. The
  /// pre-resized NSImage is what AppKit hands to NSMenuItem when the row
  /// is hosted inside a `Menu`; without this, the source NSImage retains
  /// its native ~256pt size and the menu row is forced to that height.
  @ViewBuilder
  static func icon(for descriptor: EditorDescriptor) -> some View {
    switch descriptor.launchMode {
    case .shellEditor:
      Image(systemName: "terminal")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    case .directory, .applicationWithArguments:
      if let appURL = descriptor.appURL {
        Image(nsImage: resized(NSWorkspace.shared.icon(forFile: appURL.path), to: 16))
          .renderingMode(.original)
          .accessibilityHidden(true)
      } else {
        Image(systemName: "app.dashed")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
    }
  }

  /// Redraws an NSImage at the requested point-size square so its
  /// intrinsic size matches the menu row's expected glyph slot.
  /// SwiftUI's `.resizable()` only affects the SwiftUI rendering pass,
  /// not what AppKit reads when bridging to NSMenuItem.
  private static func resized(_ image: NSImage, to side: CGFloat) -> NSImage {
    let size = NSSize(width: side, height: side)
    let resized = NSImage(size: size)
    resized.lockFocus()
    image.draw(
      in: NSRect(origin: .zero, size: size),
      from: NSRect(origin: .zero, size: image.size),
      operation: .sourceOver,
      fraction: 1.0
    )
    resized.unlockFocus()
    return resized
  }

  /// Standard row content for every editor dropdown — a SwiftUI `Label`
  /// whose `Text` + `Image` slots AppKit recognizes when the row is
  /// hosted inside a native `Menu` (i.e. the Worktree-header Open-in
  /// caret). A plain `HStack { icon; Text }` would be rendered as a
  /// custom `NSView` per row, making the menu rows much taller than
  /// the standard Settings → Default Editor dropdown.
  @ViewBuilder
  static func row(for descriptor: EditorDescriptor) -> some View {
    Label {
      Text(descriptor.displayName)
    } icon: {
      icon(for: descriptor)
    }
    .labelStyle(.titleAndIcon)
  }

  /// Flat priority-ordered list of installed descriptors, following
  /// `EditorRegistry.menuOrder`. Kept for callers that still render a single flat
  /// list; new pickers should prefer `sortedGroups` so the rendered menu shows
  /// section dividers between editors, terminals, git clients, and the shell
  /// pseudo-editor.
  static func sorted(_ installed: [EditorDescriptor]) -> [EditorDescriptor] {
    let byID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
    return EditorRegistry.menuOrder.compactMap { byID[$0] }
  }

  /// Priority-ordered groups of installed descriptors. Each non-empty group is one
  /// section in an Open-in picker; rendering each group inside its own SwiftUI
  /// `Section { ... }` block paints a divider between them in `.menu`-style
  /// pickers. Group order mirrors `EditorRegistry.menuOrder`:
  /// 1. Editors (`editorPriority` + Xcode)
  /// 2. Terminals (`terminalPriority`)
  /// 3. Git clients (`gitClientPriority`)
  /// 4. Finder + `$EDITOR` shell pseudo-entry
  static func sortedGroups(_ installed: [EditorDescriptor]) -> [[EditorDescriptor]] {
    let byID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
    let groups: [[EditorID]] = [
      EditorRegistry.editorPriority + ["xcode"],
      EditorRegistry.terminalPriority,
      EditorRegistry.gitClientPriority,
      ["finder", EditorRegistry.shellEditorID],
    ]
    return
      groups
      .map { ids in ids.compactMap { byID[$0] } }
      .filter { !$0.isEmpty }
  }
}
