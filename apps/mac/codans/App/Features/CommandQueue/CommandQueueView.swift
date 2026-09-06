import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet-hosted editor for a Pane's Command Queue (⌘⌥L, or the pane's
/// actions menu).
///
/// Laid out like a chat box: the queue reads top-down as the history — a
/// native list, present only while something is queued — and the composer
/// sits under it, carrying its own controls inside the box — the
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
  /// Rows are uniform — one line of command, one caption — so the list's
  /// height is arithmetic rather than measured; `List` cannot size itself
  /// to its content.
  private static let rowHeight: CGFloat = 44
  private static let rowInsets = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 10)
  private static let maxVisibleRows = 7
  /// About five lines of the composer's monospaced 12pt.
  private static let editorHeight: CGFloat = 88
  private static let composerFont = Font.system(size: 12, design: .monospaced)

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if !entries.isEmpty {
        queuedList
      }
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

  /// A native bordered list, shown only while something is queued: an empty
  /// queue needs no box, and the composer moves up under the title.
  private var queuedList: some View {
    ScrollViewReader { proxy in
      List {
        ForEach(entries) { entry in
          row(entry)
            .id(entry.id)
            .listRowInsets(Self.rowInsets)
            .listRowSeparator(.hidden)
        }
      }
      .listStyle(.bordered)
      .alternatingRowBackgrounds(.enabled)
      .frame(height: Self.listHeight(for: entries.count))
      // Newest at the bottom, like a transcript: follow it as entries land.
      .onChange(of: entries.count) { _, _ in
        guard let last = entries.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
      }
    }
  }

  /// One row per entry up to `maxVisibleRows`, plus the bordered style's
  /// top and bottom hairlines.
  private static func listHeight(for count: Int) -> CGFloat {
    CGFloat(min(count, maxVisibleRows)) * rowHeight + 2
  }

  private func row(_ entry: QueuedCommand) -> some View {
    HStack(spacing: 10) {
      Image(systemName: entry.timing.fireDate == nil ? "arrow.turn.down.right" : "clock")
        .font(.system(size: 12))
        .frame(width: 16)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(Self.oneLine(entry.text))
          .font(Self.composerFont)
          .lineLimit(1)
          .truncationMode(.tail)
        Text(CommandQueueBadgeStyle.description(of: entry.timing))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(height: Self.rowHeight - Self.rowInsets.top - Self.rowInsets.bottom)
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
    // Rows are one line; the full body is a hover away.
    .help(entry.text)
  }

  /// A multi-line body on one line, with its breaks kept visible so
  /// `echo hi ⏎ date` does not read as one command.
  private static func oneLine(_ text: String) -> String {
    text
      .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
      .joined(separator: " ⏎ ")
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

  /// The composer's box. Its edge takes the accent colour while the editor
  /// has focus, standing in for the focus ring the editor itself no longer
  /// draws.
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
