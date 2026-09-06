import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet-hosted editor for a Pane's Command Queue (⌘⌥L, or the pane's
/// actions menu).
///
/// Laid out like a chat box: the queue reads top-down as the history, the
/// multi-line composer sits under it, and the bottom bar pairs the send
/// timing on the left with the send button on the right. Return sends and
/// ⇧Return breaks a line. The composer is multi-line because a prompt to an
/// agent often is, and `TerminalClient.sendCommand` delivers the body as one
/// paste, so those line breaks arrive as line breaks rather than as
/// submissions.
///
/// Presented with `.sheet(item:)` like the app's other dialogs, sharing their
/// container metrics (`padding(24)`, fixed width, headline + caption header,
/// Cancel on `.cancelAction`).
///
/// The queued list is read from the live catalog rather than from reducer
/// state: an entry that drains while the sheet is open should vanish from the
/// list on the same frame it is typed into the terminal.
struct CommandQueueView: View {
  @Bindable var store: StoreOf<CommandQueueFeature>
  /// Sent by Cancel and Escape. Dismissal is "parent nils the `@Presents`
  /// slot".
  let onDismiss: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @FocusState private var draftFocused: Bool

  private static let width: CGFloat = 480
  private static let boxCornerRadius: CGFloat = 6
  /// The list keeps a floor so an empty queue still reads as the place
  /// entries will appear, and the composer does not jump when the first one
  /// lands.
  private static let queueMinHeight: CGFloat = 112
  private static let queueMaxHeight: CGFloat = 200
  /// About five lines of the composer's monospaced 12pt.
  private static let composerHeight: CGFloat = 92
  private static let composerFont = Font.system(size: 12, design: .monospaced)

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      queuedList
      composer
      if store.mode == .scheduled {
        scheduleControls
      }
      bottomBar
    }
    .padding(24)
    .frame(width: Self.width)
    .onAppear { draftFocused = true }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Command Queue")
        .font(.headline)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  /// Names the pane being edited. Truncates in the middle so a long worktree
  /// path keeps both its project and its branch visible.
  private var subtitle: String {
    guard let paneLabel else { return "Commands wait here until this pane is ready." }
    return "Queued on \(paneLabel)."
  }

  // MARK: - Queued list

  private var queuedList: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Queued")
          .font(.subheadline.weight(.medium))
        if !entries.isEmpty {
          Text("\(entries.count)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Spacer()
        Button("Clear All") { store.send(.clearAllTapped) }
          .buttonStyle(.link)
          .font(.caption)
          .disabled(entries.isEmpty)
          // Kept in the row (hidden, not removed) so the header's height does
          // not change with the first entry.
          .opacity(entries.isEmpty ? 0 : 1)
      }

      ScrollViewReader { proxy in
        ScrollView {
          if entries.isEmpty {
            Text("Nothing queued yet")
              .font(.caption)
              .foregroundStyle(.tertiary)
              .frame(maxWidth: .infinity, minHeight: Self.queueMinHeight)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider() }
                row(entry)
                  .id(entry.id)
              }
            }
          }
        }
        .scrollIndicators(.automatic)
        .frame(minHeight: Self.queueMinHeight, maxHeight: Self.queueMaxHeight)
        // Newest at the bottom, like a transcript: follow it as entries land.
        .onChange(of: entries.count) { _, _ in
          guard let last = entries.last else { return }
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
      .background(box)
      .overlay(boxEdge(focused: false))
    }
  }

  private func row(_ entry: QueuedCommand) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: entry.timing.fireDate == nil ? "arrow.turn.down.right" : "clock")
        .font(.caption)
        .frame(width: 14)
        .padding(.top, 2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.text)
          .font(Self.composerFont)
          .lineLimit(3)
          .truncationMode(.tail)
        Text(CommandQueueBadgeStyle.description(of: entry.timing))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
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
  }

  // MARK: - Composer

  private var composer: some View {
    TextEditor(text: $store.draft.sending(\.draftChanged))
      .font(Self.composerFont)
      .scrollContentBackground(.hidden)
      .focusEffectDisabled()
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
      .frame(height: Self.composerHeight)
      .background(box)
      .overlay(boxEdge(focused: draftFocused))
      .overlay(alignment: .topLeading) {
        if store.draft.isEmpty {
          // `TextEditor` has no placeholder of its own; this sits where the
          // first line of text will, matching the text container's inset.
          Text("Command or prompt…")
            .font(Self.composerFont)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .allowsHitTesting(false)
        }
      }
      .focused($draftFocused)
      .onKeyPress(.return, phases: .down) { press in
        // Return sends; ⇧Return and ⌥Return break a line — the chat
        // convention the layout borrows. An empty draft swallows Return
        // rather than opening with a blank line.
        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
          return .ignored
        }
        if store.canSubmit {
          store.send(.submitted)
        }
        return .handled
      }
      .onKeyPress(.escape) {
        // NSTextView binds Escape to word completion; claim it so the sheet
        // closes like the app's other dialogs do.
        onDismiss()
        return .handled
      }
      .accessibilityLabel("Command")
  }

  private var scheduleControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("At")
          .font(.callout)
          .foregroundStyle(.secondary)
        DatePicker(
          "",
          selection: $store.scheduledAt.sending(\.scheduledAtChanged),
          displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        // `.field`, not `.compact`: a stepper field is typeable, needs no
        // popover, and matches the Date & Time idiom this reads as.
        .datePickerStyle(.field)
      }

      HStack(spacing: 8) {
        Toggle(
          "Repeat every",
          isOn: $store.repeatEnabled.sending(\.repeatEnabledChanged)
        )
        .font(.callout)
        TextField(
          "",
          value: $store.repeatAmount.sending(\.repeatAmountChanged),
          format: .number
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 52)
        .disabled(!store.repeatEnabled)
        Picker("", selection: $store.repeatUnit.sending(\.repeatUnitChanged)) {
          ForEach(CommandQueueFeature.IntervalUnit.allCases, id: \.self) { unit in
            Text(unit.title).tag(unit)
          }
        }
        .labelsHidden()
        .frame(width: 96)
        .disabled(!store.repeatEnabled)
      }
    }
  }

  // MARK: - Bottom bar

  /// Send timing on the left, actions on the right. Cancel closes the sheet
  /// and discards the draft; it does not undo entries already added, which
  /// land in the catalog the moment they are sent. The send button stays put
  /// rather than dismissing, because queueing several commands in one
  /// sitting is the common case.
  private var bottomBar: some View {
    HStack(spacing: 10) {
      Picker("Send", selection: $store.mode.sending(\.modeChanged)) {
        ForEach(CommandQueueFeature.State.Mode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      .help(modeHint)
      Text("⇧↩ new line")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
      Button("Cancel", role: .cancel) { onDismiss() }
        .keyboardShortcut(.cancelAction)
      Button(sendTitle) { store.send(.submitted) }
        // ⌘↩ as well as the composer's plain Return, so sending works from
        // the schedule fields too.
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(!store.canSubmit)
    }
  }

  private var sendTitle: String {
    switch store.mode {
    case .now: return "Send"
    case .afterCurrentTask: return "Queue"
    case .scheduled: return "Schedule"
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

  // MARK: - Chrome

  /// The list and the composer share one box treatment so the sheet reads
  /// as two panes of the same surface, the way a transcript and its input
  /// do.
  private var box: some View {
    RoundedRectangle(cornerRadius: Self.boxCornerRadius, style: .continuous)
      .fill(Color(nsColor: .textBackgroundColor))
  }

  private func boxEdge(focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: Self.boxCornerRadius, style: .continuous)
      .stroke(
        focused ? Color.accentColor : Color(nsColor: .separatorColor),
        lineWidth: 1
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
