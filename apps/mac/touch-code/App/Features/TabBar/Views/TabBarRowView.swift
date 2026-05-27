import ComposableArchitecture
import SwiftUI
import TouchCodeCore
import UniformTypeIdentifiers

/// Horizontal row of tab chips. Kept thin so feature dispatch stays out of
/// the chip views — select / close / rename / reorder callbacks come from
/// the parent.
///
/// Chips sit flush against one another (`spacing: 0`) and a thin vertical
/// separator is stamped between any two adjacent non-active chips. The
/// separator is suppressed on either side of the active chip so its
/// accent underline visually carries the boundary.
///
/// Reorder: each chip emits its `TabID.raw.uuidString` via `.onDrag`; a
/// sibling `ChipDropDelegate` attached to every chip translates the drop
/// target into a reordered id list and dispatches once via
/// `onReorder`. A `spring(response: 0.3, dampingFraction: 0.85)` on the
/// id list animates the layout settle after the catalog updates.
struct TabBarRowView: View {
  let tabs: [TouchCodeCore.Tab]
  let activeTabID: TabID?
  /// Per-tab dirty lookup. Typically backed by
  /// `HierarchyManager.tabIsDirty(_:)` so SwiftUI observation re-renders
  /// the row when a pane's running state flips. Default is a no-op
  /// returning `false` for callers / previews that do not need dirty
  /// coverage.
  var isDirty: (TabID) -> Bool = { _ in false }
  let onSelect: (TabID) -> Void
  let onClose: (TabID) -> Void
  let onMiddleClick: (TabID) -> Void
  let onCloseOthers: (TabID) -> Void
  let onCloseToRight: (TabID) -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: (TabID) -> Void
  let onChangeColorRequested: (TabID) -> Void
  let onChangeIconRequested: (TabID) -> Void
  let onCopyID: (TabID) -> Void
  let onReorder: @MainActor @Sendable ([TabID]) -> Void
  /// Fires whenever a chip resolves a non-empty live title (OSC tabTitle
  /// / title / pwd basename). The parent persists this onto the tab so
  /// the chip can fall back to it across app launches before the
  /// surface respawns. Default no-op keeps previews / call sites that
  /// don't care about cross-launch titles compiling without changes.
  var onCacheLiveTitle: (TabID, String) -> Void = { _, _ in }

  @Environment(CommandKeyObserver.self) private var commandKeyObserver
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
        ResolvingTabChipView(
          tab: tab,
          isActive: activeTabID == tab.id,
          isDirty: isDirty(tab.id),
          isOnlyTab: tabs.count <= 1,
          isLastTab: index == tabs.count - 1,
          chordHint: chordHint(for: index + 1),
          onSelect: { onSelect(tab.id) },
          onClose: { onClose(tab.id) },
          onMiddleClick: { onMiddleClick(tab.id) },
          onCloseOthers: { onCloseOthers(tab.id) },
          onCloseToRight: { onCloseToRight(tab.id) },
          onCloseAll: onCloseAll,
          onRenameRequested: { onRenameRequested(tab.id) },
          onChangeColor: { onChangeColorRequested(tab.id) },
          onChangeIcon: { onChangeIconRequested(tab.id) },
          onCopyID: { onCopyID(tab.id) },
          tabColor: tab.color,
          icon: tab.resolvedIcon(autoFallback: nil),
          onCacheLiveTitle: { title in onCacheLiveTitle(tab.id, title) }
        )
        .id(tab.id)
        .onDrag {
          NSItemProvider(object: tab.id.raw.uuidString as NSString)
        }
        .onDrop(
          of: [.plainText],
          delegate: ChipDropDelegate(
            targetID: tab.id,
            tabs: tabs,
            commit: onReorder
          )
        )
        if index < tabs.count - 1 {
          Rectangle()
            .fill(TabBarColors.divider)
            .frame(
              width: TabBarMetrics.dividerWidth,
              height: TabBarMetrics.dividerHeight
            )
        }
      }
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tabs.map(\.id))
  }

  /// Resolves the registry chord (`switchToTabN`) to a display string while ⌘ is held.
  /// Returned to `TabChipView.chordHint` so the chord renders inside the chip's trailing
  /// slot (replacing the close button while held). Beyond ten tabs the schema has no
  /// chord; returns nil and the chip keeps its close-button slot.
  private func chordHint(for tabIndex: Int) -> String? {
    guard commandKeyObserver.isCommandHeld,
      let id = CommandID.switchToTab(index: tabIndex),
      let resolved = resolvedShortcuts[id], resolved.isEnabled,
      let binding = resolved.binding
    else { return nil }
    return ShortcutDisplay.chord(for: binding)
  }
}

/// Per-chip wrapper that resolves the live display title and forwards
/// everything else to `TabChipView`. The view exists for one reason:
/// `SurfaceInfo` is `@Observable`, and SwiftUI registers an observer at
/// the body that reads its properties. By making each chip its own view
/// and reading `info.title` here, the observation lives on this view's
/// body — so an OSC push only invalidates the affected chip rather than
/// being dropped because the access happened inside a `ForEach` builder
/// of an upstream view that didn't establish its own tracking context.
///
/// Title priority:
/// 1. `tab.name` (manual rename — sticky, ignores OSC).
/// 2. focused pane's `info.tabTitle` (OSC 2 / set_tab_title).
/// 3. focused pane's `info.title` (OSC 0 / set_title).
/// 4. focused pane's `info.pwd` basename.
/// 5. `tab.cachedDisplayTitle` (last live value persisted to the catalog).
/// 6. focused (or first) pane's `workingDirectory` basename — always
///    present on the persisted catalog, so even cold-launched chips
///    have a meaningful label before the surface respawns.
/// 7. Empty string as a last-resort defensive default.
///
/// The cache exists because surfaces are spawned lazily — on cold launch
/// inactive tabs have no live `SurfaceInfo` yet, so without the cache
/// every previously-named tab would briefly read as the workingDirectory
/// basename until the shell re-emits an OSC title (and stay there, for
/// tabs the user does not re-open during the session).
private struct ResolvingTabChipView: View {
  let tab: TouchCodeCore.Tab
  let isActive: Bool
  let isDirty: Bool
  let isOnlyTab: Bool
  let isLastTab: Bool
  /// Forwarded to `TabChipView.chordHint`. Resolved at the row level so this view stays
  /// out of the shortcut-environment plumbing.
  let chordHint: String?
  let onSelect: () -> Void
  let onClose: () -> Void
  let onMiddleClick: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: () -> Void
  let onChangeColor: () -> Void
  let onChangeIcon: () -> Void
  let onCopyID: () -> Void
  let tabColor: TabColor?
  let icon: String?
  let onCacheLiveTitle: (String) -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @Environment(RollupIndexProvider.self) private var notificationRollup: RollupIndexProvider?
  @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
  @Dependency(TerminalClient.self) private var terminalClient

  var body: some View {
    let live = liveResolvedTitle
    TabChipView(
      title: resolvedTitle(live: live),
      isActive: isActive,
      isDirty: isDirty,
      isOnlyTab: isOnlyTab,
      isLastTab: isLastTab,
      hasUnreadNotification: notificationRollup?.current.unreadTabs.contains(tab.id) == true
        && settingsStore?.settings.notifications.tabBellEnabled != false,
      chordHint: chordHint,
      onSelect: onSelect,
      onClose: onClose,
      onMiddleClick: onMiddleClick,
      onCloseOthers: onCloseOthers,
      onCloseToRight: onCloseToRight,
      onCloseAll: onCloseAll,
      onRenameRequested: onRenameRequested,
      onChangeColor: onChangeColor,
      onChangeIcon: onChangeIcon,
      onCopyID: onCopyID,
      tabColor: tabColor,
      icon: icon
    )
    .onChange(of: live, initial: true) { _, newLive in
      // Only persist once the surface has actually produced a live
      // title — never overwrite the cache with `nil` (e.g. surface not
      // yet spawned on cold launch), otherwise a freshly-loaded catalog
      // would clobber its own cache before the shell pushes anything.
      guard let newLive, newLive != tab.cachedDisplayTitle else { return }
      onCacheLiveTitle(newLive)
    }
  }

  /// Title sourced strictly from the live focused-pane `SurfaceInfo`.
  /// Returns `nil` when the surface hasn't been spawned yet or the shell
  /// hasn't pushed any of OSC 2 / OSC 0 / OSC 7 — letting the caller
  /// decide whether to fall back to the persisted cache or "Tab N".
  private var liveResolvedTitle: String? {
    let paneID = hierarchyManager.lastFocusedPane(in: tab.id) ?? tab.panes.first?.id
    guard let paneID, let surface = terminalClient.surface(paneID) else { return nil }
    let info = surface.info
    // Read all observable properties up-front so SwiftUI registers
    // observation on every one — `if let` short-circuits would skip
    // subsequent reads and miss future updates on those keypaths.
    let tabTitleValue = info.tabTitle
    let titleValue = info.title
    let pwdValue = info.pwd
    if let t = tabTitleValue, !t.isEmpty { return t }
    if let t = titleValue, !t.isEmpty { return t }
    if let pwd = pwdValue {
      let basename = (pwd as NSString).lastPathComponent
      if !basename.isEmpty { return basename }
    }
    return nil
  }

  private func resolvedTitle(live: String?) -> String {
    if let name = tab.name, !name.isEmpty { return name }
    if let live { return live }
    if let cached = tab.cachedDisplayTitle, !cached.isEmpty { return cached }
    let pane =
      tab.panes.first { $0.id == hierarchyManager.lastFocusedPane(in: tab.id) }
      ?? tab.panes.first
    if let pane {
      let basename = (pane.workingDirectory as NSString).lastPathComponent
      if !basename.isEmpty { return basename }
    }
    return ""
  }
}

/// DropDelegate that treats the drop payload as a source `TabID.raw` UUID
/// string, computes the new order (source removed + reinserted at the
/// target's index), and dispatches a single `commit` — matching the
/// exec-plan's D3 ("dispatch once on drop, not per tick"). Intra-row
/// self-drops are no-ops.
private struct ChipDropDelegate: DropDelegate {
  let targetID: TabID
  let tabs: [TouchCodeCore.Tab]
  let commit: @MainActor @Sendable ([TabID]) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.plainText])
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let provider = info.itemProviders(for: [.plainText]).first else {
      return false
    }
    let targetID = self.targetID
    let ids = tabs.map(\.id)
    provider.loadObject(ofClass: NSString.self) { [commit] loaded, _ in
      guard let raw = loaded as? String,
        let uuid = UUID(uuidString: raw)
      else { return }
      let sourceID = TabID(raw: uuid)
      guard sourceID != targetID,
        let sourceIdx = ids.firstIndex(of: sourceID),
        let targetIdx = ids.firstIndex(of: targetID)
      else { return }
      var reordered = ids
      reordered.remove(at: sourceIdx)
      // After removing the source, the original target index still
      // points at the same chip (shifted left by one if source < target).
      // Inserting `sourceID` at that index yields "drop into target's
      // current slot" semantics — the dropped chip lands where the
      // target was and pushes the target one step toward the source's
      // old side. This matches macOS Finder / Safari tab drag behavior.
      // Clamp defensively in case the array shrinks unexpectedly.
      reordered.insert(sourceID, at: min(targetIdx, reordered.count))
      // NSItemProvider invokes this callback off the main actor; hop back
      // onto MainActor so the non-Sendable TCA-store closure fires on the
      // correct isolation domain.
      Task { @MainActor in
        commit(reordered)
      }
    }
    return true
  }
}
