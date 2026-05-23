import ComposableArchitecture
import SwiftUI
import TouchCodeCore

/// v1 status-bar bell. Renders a `bell` SF Symbol with an unread-count
/// badge sourced from `RollupIndexProvider.current.globalUnreadCount`.
/// Tapping anchors a popover that lists the inbox newest-first; clicking
/// a row dispatches `RootFeature.focusHierarchyPath` and marks the row
/// read.
///
/// This is the only popover entry into the inbox. Per-level indicators
/// in the sidebar / tab bar / pane chrome are visual-only.
struct InboxBellView: View {
  /// Dispatches `RootFeature.focusHierarchyPath` for a tapped row.
  /// Wired by ContentView; passing a closure rather than the root store
  /// keeps WorktreeDetailView from needing the full RootFeature scope.
  let onFocusHierarchyPath: (InboxEntry.SourcePath) -> Void
  /// `RootFeature.State.inboxBellPopoverTrigger` — bumped to a fresh UUID
  /// by the ⌘U menu chord. `.onChange` below flips `popoverShown` so the
  /// popover anchors itself to this button identically to a user click.
  let popoverTrigger: UUID
  @Environment(NotificationStore.self) private var inbox: NotificationStore?
  @Environment(RollupIndexProvider.self) private var rollup: RollupIndexProvider?
  @Environment(SettingsStore.self) private var settingsStore: SettingsStore?
  @Environment(\.resolvedShortcuts) private var resolvedShortcuts: ResolvedShortcutMap

  @State private var popoverShown = false
  @State private var unreadOnly = true

  var body: some View {
    // User-controlled visual filter (Settings → Notifications → In-app → Status-bar bell).
    // Hides the entire button, not just the badge — a dead bell in the toolbar
    // would be confusing. Inbox itself still receives entries regardless.
    if settingsStore?.settings.notifications.statusBarBellEnabled == false {
      EmptyView()
    } else {
      bellButton
    }
  }

  @ViewBuilder
  private var bellButton: some View {
    let count = rollup?.current.globalUnreadCount ?? 0
    Button(action: { popoverShown.toggle() }) {
      HStack(spacing: 4) {
        Image(systemName: count > 0 ? "bell.fill" : "bell")
          .font(.title3)
          .foregroundStyle(count > 0 ? Color.orange : Color.primary)
        if count > 0 {
          Text(badgeLabel(count))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
        }
      }
      // Optical balance — *not* numeric symmetry. SF Symbols' bell glyph
      // ships with built-in visual whitespace around the bell shape,
      // while a tight digit like "3" inks right up to its bounding box.
      // The same numeric padding therefore reads as "lots of space on
      // the left, none on the right." Trailing gets extra to compensate.
      .padding(.leading, 6)
      .padding(.trailing, 10)
      .frame(minHeight: 24)
    }
    .buttonStyle(.plain)
    .help(tooltipLabel)
    .accessibilityLabel(accessibilityLabel)
    .onChange(of: popoverTrigger) { _, _ in
      popoverShown = true
    }
    .popover(isPresented: $popoverShown, arrowEdge: .top) {
      InboxPopoverContent(
        unreadOnly: $unreadOnly,
        onRowTap: { entry in
          inbox?.markRead(id: entry.id)
          popoverShown = false
          onFocusHierarchyPath(entry.source)
        },
        onMarkAllRead: { inbox?.markAllRead() },
        onClose: { popoverShown = false }
      )
      .frame(minWidth: 320, idealWidth: 360, maxWidth: 480, minHeight: 200, idealHeight: 360)
    }
  }

  private func badgeLabel(_ count: Int) -> String {
    count >= 100 ? "99+" : String(count)
  }

  private var accessibilityLabel: String {
    let count = rollup?.current.globalUnreadCount ?? 0
    if count == 0 { return "Notifications: no unread" }
    return "Notifications: \(count) unread"
  }

  /// Tooltip on the bell. Always reads "Show Unread Notifications" plus
  /// the resolved chord for `.showUnread` in parens. We trail the chord
  /// off when the user has disabled the binding so the tooltip degrades
  /// to plain text rather than rendering an empty `()`.
  private var tooltipLabel: String {
    let base = "Show Unread Notifications"
    if let resolved = resolvedShortcuts[.showUnread], resolved.isEnabled,
      let binding = resolved.binding
    {
      return "\(base) (\(ShortcutDisplay.chord(for: binding)))"
    }
    if let fallback = ShortcutSchema.app.entry(for: .showUnread)?.defaultBinding {
      return "\(base) (\(ShortcutDisplay.chord(for: fallback)))"
    }
    return base
  }
}

/// Popover body. Holds the row list + filter chip + Mark all read.
private struct InboxPopoverContent: View {
  @Binding var unreadOnly: Bool
  let onRowTap: (InboxEntry) -> Void
  let onMarkAllRead: () -> Void
  /// Invoked when Esc lands in the popover. NSPopover doesn't dismiss on
  /// Esc by default, and a hidden `.cancelAction` button doesn't fire
  /// while focus stays on the anchor toolbar button — so we force the
  /// root focusable, grab first responder onAppear, and route Esc via
  /// `.onKeyPress`. Same pattern the Command Palette uses.
  let onClose: () -> Void

  @Environment(NotificationStore.self) private var inbox: NotificationStore?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if filtered.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filtered) { entry in
              InboxRowView(entry: entry, onTap: { onRowTap(entry) })
              Divider()
            }
          }
        }
      }
    }
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onAppear { focused = true }
    .onKeyPress(.escape) {
      onClose()
      return .handled
    }
  }

  private var filtered: [InboxEntry] {
    let entries = inbox?.entries ?? []
    return unreadOnly ? entries.filter(\.isUnread) : entries
  }

  /// Header dropped its "Notifications" title (HAN-56) — the bell anchor
  /// already names the popover and the redundant headline ate vertical
  /// space without earning it. The All/Unread picker is centred via a
  /// ZStack so its horizontal anchor stays fixed regardless of the Mark
  /// all read button's width / disabled state; the button rides on a
  /// trailing-aligned overlay HStack so it doesn't displace the picker.
  private var header: some View {
    ZStack {
      Picker("", selection: $unreadOnly) {
        Text("Unread").tag(true)
        Text("All").tag(false)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 140)

      HStack {
        Spacer()
        Button("Mark all read", action: onMarkAllRead)
          .buttonStyle(.plain)
          .font(.caption)
          .disabled((inbox?.unreadCount ?? 0) == 0)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "tray")
        .font(.title)
        .foregroundStyle(.secondary)
      Text(unreadOnly ? "No unread notifications" : "No notifications yet")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }
}

private struct InboxRowView: View {
  let entry: InboxEntry
  let onTap: () -> Void

  /// Dot column geometry. Kept as static constants so row 1's leading
  /// indent (`dotColumnWidth + dotSpacing`) cannot drift away from
  /// row 2's actual dot column.
  fileprivate static let dotSize: CGFloat = 6
  fileprivate static let dotSpacing: CGFloat = 8
  fileprivate static let dotColumnWidth: CGFloat = dotSize + dotSpacing

  /// Formatter is allocated once for the whole popover lifetime; building
  /// a fresh `RelativeDateTimeFormatter` per row would otherwise spin up
  /// a CFLocale, calendar, and ICU context on every redraw.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
  }()

  @Environment(HierarchyManager.self) private var hierarchyManager: HierarchyManager?
  @State private var isHovering = false

  var body: some View {
    Button(action: onTap) {
      // HAN-78: row 1 is `<title> - <body>` (uniform font + colour so
      // the line reads as one continuous sentence); row 2 is the
      // source breadcrumb + age. The dot indicator stays on row 1 so
      // it sits next to the content line; row 2 carries a matching
      // leading indent (`dotColumnWidth + dotSpacing`) so the two
      // rows' text columns line up.
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .center, spacing: Self.dotSpacing) {
          // Filled circle on unread (yellow for taskFinished, orange
          // for the more urgent waitingForInput); empty space on read
          // so we never show a check-shaped icon in front of an
          // unread row (the previous green checkmark.circle.fill read
          // as 'already done' and was the bug Gump flagged).
          unreadDot
            .frame(width: Self.dotSize, height: Self.dotSize)
          Text("\(entry.title) - \(entry.body)")
            .font(.callout)
            .foregroundStyle(entry.isUnread ? Color.primary : Color.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          // Hover-only nav cue: dimmed-zero by default, fades in and
          // slides 3 pt right while the cursor is over the row.
          // Suppressed on read rows since they're not navigable
          // (HAN-56).
          if entry.isUnread {
            Image(systemName: "arrow.right")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .opacity(isHovering ? 0.9 : 0)
              .offset(x: isHovering ? 3 : 0)
              .animation(.easeInOut(duration: 0.15), value: isHovering)
              .accessibilityHidden(true)
          }
        }

        HStack(spacing: 6) {
          if let breadcrumb, !breadcrumb.isEmpty {
            Text(breadcrumb)
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer(minLength: 6)
          Text(relativeAge)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.leading, Self.dotColumnWidth)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(isHovering ? Color.gray.opacity(0.08) : Color.clear)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    // Read rows are non-navigable (HAN-56). Block hit-testing entirely
    // so the row neither fires onTap nor lights up the hover background
    // — the inbox keeps them around as visual history, not as buttons.
    .allowsHitTesting(entry.isUnread)
  }

  /// Read state has no leading glyph (a check-shape next to a row reads
  /// as "this is done/read" and conflicts with the unread row case).
  /// Unread state shows a filled dot whose colour mirrors the kind:
  /// orange for waitingForInput (more urgent), yellow for taskFinished
  /// (matches the bell glyph theme).
  @ViewBuilder
  private var unreadDot: some View {
    if entry.isUnread {
      Circle()
        .fill(entry.kind == .waitingForInput ? Color.orange : Color.yellow)
        .accessibilityLabel(entry.kind == .waitingForInput ? "Waiting for input" : "Unread")
    } else {
      Color.clear
    }
  }

  /// Breadcrumb for the entry's source path: `<project>·<worktree>`,
  /// matching the OS banner footer format (HAN-78). Resolved live from
  /// `HierarchyManager.catalog` so a project / worktree rename reflects
  /// in the popover without a save or reload cycle. Returns nil when the
  /// project has been deleted (G3 dead-target case) so the row simply
  /// omits the breadcrumb.
  private var breadcrumb: String? {
    guard let mgr = hierarchyManager,
      let project = mgr.catalog.projects.first(where: { $0.id == entry.source.projectID })
    else { return nil }
    var parts: [String] = [project.name]
    if let worktree = project.worktrees.first(where: { $0.id == entry.source.worktreeID }) {
      parts.append(worktree.name)
    }
    return parts.joined(separator: "·")
  }

  private var relativeAge: String {
    Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date())
  }
}
