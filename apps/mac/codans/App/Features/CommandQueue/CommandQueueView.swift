import CodansCore
import ComposableArchitecture
import SwiftUI

/// Overlay UI for a Pane's Command Queue (⌘⌥L, or a click on the pane's
/// queue badge). Presented as a floating card over the split viewport,
/// mirroring `CommandPaletteView`'s presentation so the two keyboard-summoned
/// surfaces read as siblings.
///
/// The queued list is read from the live catalog rather than from reducer
/// state: an entry that drains while the panel is open should vanish from the
/// list on the same frame it is typed into the terminal.
struct CommandQueueView: View {
  @Bindable var store: StoreOf<CommandQueueFeature>
  /// Sent on Esc / scrim tap. Dismissal is "parent nils the `@Presents`
  /// slot", same contract as the Command Palette.
  let onDismiss: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @FocusState private var draftFocused: Bool

  private let cardCornerRadius: CGFloat = 12

  var body: some View {
    ZStack(alignment: .top) {
      Color.clear
        .contentShape(.rect)
        .onTapGesture { onDismiss() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dismiss Command Queue")

      VStack(spacing: 0) {
        header
        Divider()
        composer
        Divider()
        queueList
      }
      .frame(maxWidth: 560)
      // Opaque, deliberately — no blur of any kind.
      //
      // Both a translucent `Material` and an `NSVisualEffectView` backdrop
      // produced the same defect here: a blurred slab, correctly clipped to
      // nothing, floating over the card AND the terminal below it, vanishing
      // with the panel. A backdrop filter needs its own compositing layer by
      // construction, and that layer was escaping the card's `clipShape` and
      // rendering at a stale frame. A flat fill needs no layer of its own —
      // it draws straight into the parent's display list — so the whole
      // class of defect goes away. It also reads better over a busy
      // terminal, which is what is always behind this card.
      .background(
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
          .fill(Color(nsColor: .windowBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      )
      .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
      // Restores the sense of a floating panel that the blur used to carry.
      .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
      .padding(.top, 80)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { draftFocused = true }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: CommandQueueBadgeStyle.symbol)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("Command Queue")
        .font(.system(size: 13, weight: .semibold))
      if let target = paneLabel {
        Text(target)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      if !entries.isEmpty {
        Button("Clear All") { store.send(.clearAllTapped) }
          .buttonStyle(.link)
          .font(.system(size: 11))
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 38)
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Single-line by design: one entry is one command and one Return. A
      // multi-line draft would put embedded newlines into the delivered
      // text, and each of those submits on its own — the first line would
      // fire and the rest would arrive as separate prompts.
      TextField("Command to send…", text: $store.draft.sending(\.draftChanged))
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($draftFocused)
        .onKeyPress(.escape) {
          onDismiss()
          return .handled
        }
        .onKeyPress(.return) {
          store.send(.submitted)
          return .handled
        }

      modeSelector

      if store.mode == .scheduled {
        scheduleControls
      }

      HStack {
        Text(modeHint)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(store.mode == .now ? "Send" : "Add to Queue") {
          store.send(.submitted)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!store.canSubmit)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
  }

  /// Self-drawn three-way selector instead of `Picker(.segmented)`.
  ///
  /// `.segmented` is an `NSSegmentedControl`, and this codebase has a
  /// standing rule that AppKit controls hosted inside a floating overlay
  /// misbehave in ways that are cheaper to sidestep than to diagnose (the
  /// same reasoning retired the tinted `borderedProminent` label in the PR
  /// popover). Drawing it ourselves also lets the selected segment keep a
  /// legible label in both colour schemes rather than inheriting whatever
  /// contrast AppKit picks for a tinted segment.
  private var modeSelector: some View {
    HStack(spacing: 2) {
      ForEach(CommandQueueFeature.State.Mode.allCases, id: \.self) { mode in
        modeSegment(mode)
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.06))
    )
  }

  private func modeSegment(_ mode: CommandQueueFeature.State.Mode) -> some View {
    let selected = store.mode == mode
    return Button {
      store.send(.modeChanged(mode))
    } label: {
      Text(mode.title)
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        // White on the accent fill in both schemes — the accent is
        // saturated enough that a `.primary` label would wash out in light
        // mode and disappear in dark.
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  private var scheduleControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("At").font(.system(size: 12)).foregroundStyle(.secondary)
        DatePicker(
          "",
          selection: $store.scheduledAt.sending(\.scheduledAtChanged),
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        // `.field`, not `.compact`: the compact style owns a calendar
        // popover, and a popover anchored inside a transient overlay card
        // outlives the card's own layout — it is the other candidate for
        // the blurred slab this panel was showing.
        .datePickerStyle(.field)
      }
      HStack(spacing: 8) {
        Toggle(
          "Repeat every",
          isOn: $store.repeatEnabled.sending(\.repeatEnabledChanged)
        )
        .font(.system(size: 12))
        TextField(
          "",
          value: $store.repeatAmount.sending(\.repeatAmountChanged),
          format: .number
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 56)
        .disabled(!store.repeatEnabled)
        Picker("", selection: $store.repeatUnit.sending(\.repeatUnitChanged)) {
          ForEach(CommandQueueFeature.IntervalUnit.allCases, id: \.self) { unit in
            Text(unit.title).tag(unit)
          }
        }
        .labelsHidden()
        .frame(width: 100)
        .disabled(!store.repeatEnabled)
      }
    }
  }

  private var modeHint: String {
    switch store.mode {
    case .now:
      return "Typed into the pane right away."
    case .afterCurrentTask:
      return "Waits until the pane finishes what it is doing."
    case .scheduled:
      return store.repeatInterval == nil
        ? "Fires once at the chosen time."
        : "Fires at the chosen time, then repeats."
    }
  }

  // MARK: - Queued list

  @ViewBuilder
  private var queueList: some View {
    if entries.isEmpty {
      Text("Nothing queued for this pane.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    } else {
      ScrollView {
        VStack(spacing: 1) {
          ForEach(entries) { entry in
            row(entry)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      }
      .scrollIndicators(.never)
      .frame(maxHeight: 220)
    }
  }

  private func row(_ entry: QueuedCommand) -> some View {
    HStack(spacing: 10) {
      Image(systemName: entry.timing.fireDate == nil ? "arrow.turn.down.right" : "clock")
        .font(.system(size: 11))
        .frame(width: 16)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.text)
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(2)
        Text(CommandQueueBadgeStyle.description(of: entry.timing))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        store.send(.removeTapped(entry.id))
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove queued command")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.04))
    )
  }

  // MARK: - Catalog reads

  /// Live queue for the edited pane. Read inside `body`'s tracking scope so
  /// `@Observable` re-renders the list when the runner drains an entry.
  private var entries: [QueuedCommand] {
    hierarchyManager.catalog.pane(store.paneID)?.commandQueue ?? []
  }

  /// Best-effort human label for the pane being edited — the tab's name if it
  /// has one, else its cached live title, else the pane's cwd basename.
  private var paneLabel: String? {
    for project in hierarchyManager.catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          guard let pane = tab.panes.first(where: { $0.id == store.paneID }) else { continue }
          if let name = tab.name, !name.isEmpty { return name }
          if let cached = tab.cachedDisplayTitle, !cached.isEmpty { return cached }
          return URL(fileURLWithPath: pane.workingDirectory).lastPathComponent
        }
      }
    }
    return nil
  }
}
