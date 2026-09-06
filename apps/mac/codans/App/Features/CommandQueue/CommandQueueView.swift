import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet-hosted editor for a Pane's Command Queue (⌘⌥L, or the pane's
/// actions menu).
///
/// Laid out like a chat box: the queue reads top-down as the history and the
/// composer sits under it, carrying its own controls inside the box — the
/// send timing at the bottom-left, the send button at the bottom-right, and
/// the schedule fields on a row of their own when that timing is chosen.
/// Return sends and ⇧Return breaks a line. The composer is multi-line
/// because a prompt to an agent often is, and `TerminalClient.sendCommand`
/// delivers the body as one paste, so those line breaks arrive as line
/// breaks rather than as submissions.
///
/// Presented with `.sheet(item:)` like the app's other dialogs. There is no
/// Cancel button: Escape closes it, and the composer claims that key itself
/// because `NSTextView` would otherwise spend it on word completion.
///
/// The queued list is read from the live catalog rather than from reducer
/// state: an entry that drains while the sheet is open should vanish from the
/// list on the same frame it is typed into the terminal.
struct CommandQueueView: View {
  @Bindable var store: StoreOf<CommandQueueFeature>
  /// Sent when Escape lands in the composer. Dismissal is "parent nils the
  /// `@Presents` slot".
  let onDismiss: () -> Void

  @Environment(HierarchyManager.self) private var hierarchyManager
  @FocusState private var draftFocused: Bool

  private static let width: CGFloat = 560
  private static let boxCornerRadius: CGFloat = 6
  /// The list keeps a floor so an empty queue still reads as the place
  /// entries will appear, and the composer does not jump when the first one
  /// lands.
  private static let queueMinHeight: CGFloat = 112
  private static let queueMaxHeight: CGFloat = 200
  /// About five lines of the composer's monospaced 12pt.
  private static let editorHeight: CGFloat = 88
  private static let composerFont = Font.system(size: 12, design: .monospaced)

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      queuedList
      composer
    }
    .padding(24)
    .frame(width: Self.width)
    .onAppear { draftFocused = true }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(entries.isEmpty ? "Command Queue" : "Command Queue (\(entries.count))")
        .font(.headline)
        .monospacedDigit()
      Spacer()
      if !entries.isEmpty {
        Button("Clear All") { store.send(.clearAllTapped) }
          .buttonStyle(.link)
          .font(.caption)
      }
    }
  }

  // MARK: - Queued list

  private var queuedList: some View {
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

  /// One box holding the editor and its controls, so the whole thing reads
  /// as a single input the way a chat composer does.
  private var composer: some View {
    VStack(alignment: .leading, spacing: 4) {
      editor
      if store.mode == .scheduled {
        scheduleRow
          .padding(.horizontal, 10)
      }
      HStack(spacing: 8) {
        modeMenu
        Spacer()
        sendButton
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 6)
    }
    .background(box)
    .overlay(boxEdge(focused: draftFocused))
  }

  private var editor: some View {
    TextEditor(text: $store.draft.sending(\.draftChanged))
      .font(Self.composerFont)
      .scrollContentBackground(.hidden)
      .focusEffectDisabled()
      .padding(.horizontal, 4)
      .padding(.top, 6)
      .frame(height: Self.editorHeight)
      .overlay(alignment: .topLeading) {
        if store.draft.isEmpty {
          // `TextEditor` has no placeholder of its own; this sits where the
          // first line of text will, matching the text container's inset.
          Text("Command or prompt… (⇧↩ for a new line)")
            .font(Self.composerFont)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.top, 6)
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
        onDismiss()
        return .handled
      }
      .accessibilityLabel("Command")
  }

  /// "At <date>   Repeat every <n> <unit>" on one line; the sheet is wide
  /// enough for the sentence to read left to right without wrapping.
  private var scheduleRow: some View {
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

      Toggle(
        "Repeat every",
        isOn: $store.repeatEnabled.sending(\.repeatEnabledChanged)
      )
      .font(.callout)
      .padding(.leading, 12)
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

  /// Send timing, as the small labelled menu a chat composer keeps at its
  /// bottom-left. The inline picker gives the menu its checkmarks.
  private var modeMenu: some View {
    Menu {
      Picker("Send", selection: $store.mode.sending(\.modeChanged)) {
        ForEach(CommandQueueFeature.State.Mode.allCases, id: \.self) { mode in
          Label(mode.title, systemImage: mode.symbol).tag(mode)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      Label(store.mode.title, systemImage: store.mode.symbol)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help(modeHint)
    .accessibilityLabel("Send timing")
  }

  private var sendButton: some View {
    Button {
      store.send(.submitted)
    } label: {
      Image(systemName: "arrow.up.circle.fill")
        .font(.system(size: 22))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(store.canSubmit ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    // ⌘↩ as well as the composer's plain Return, so sending works from the
    // schedule fields too.
    .keyboardShortcut(.return, modifiers: .command)
    .disabled(!store.canSubmit)
    .help("\(sendTitle) (⌘↩)")
    .accessibilityLabel(sendTitle)
  }

  private var sendTitle: String {
    switch store.mode {
    case .now: return "Send now"
    case .afterCurrentTask: return "Add to queue"
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
}

extension CommandQueueFeature.State.Mode {
  /// Glyph for the mode menu. The two queue timings share their symbols
  /// with the list rows so an entry's icon matches the menu that made it.
  fileprivate var symbol: String {
    switch self {
    case .now: return "paperplane"
    case .afterCurrentTask: return "arrow.turn.down.right"
    case .scheduled: return "clock"
    }
  }
}
