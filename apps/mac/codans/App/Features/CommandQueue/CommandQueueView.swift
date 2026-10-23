import CodansCore
import ComposableArchitecture
import SwiftUI

/// Sheet-hosted command composer. Queued commands appear in the pane overlay.
/// Return submits; Shift-Return inserts a line break; Escape closes the sheet.
struct CommandQueueView: View {
  @Bindable var store: StoreOf<CommandQueueFeature>
  /// Sent when Escape lands in the composer. Dismissal is "parent nils the
  /// `@Presents` slot".
  let onDismiss: () -> Void

  @FocusState private var draftFocused: Bool

  private static let width: CGFloat = 560
  private static let editorHeight: CGFloat = 110

  var body: some View {
    VStack(spacing: 0) {
      Text("Command Queue")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
      Form {
        Section {
          composer
        }
        if store.mode == .scheduled {
          Section("Schedule") {
            scheduleRow
          }
        }
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: Self.width)
    .onAppear { draftFocused = true }
    .onExitCommand(perform: onDismiss)
  }

  // MARK: - Composer

  /// One box holding the editor and its controls, so the whole thing reads
  /// as a single input the way a chat composer does.
  private var composer: some View {
    VStack(alignment: .leading, spacing: 4) {
      editor
      HStack(spacing: 8) {
        Spacer()
        modeMenu
        sendButton
      }
    }
  }

  private var editor: some View {
    TextEditor(text: $store.draft.sending(\.draftChanged))
      .font(.body)
      .scrollContentBackground(.hidden)
      .focusEffectDisabled()
      .frame(height: Self.editorHeight)
      .overlay(alignment: .topLeading) {
        if store.draft.isEmpty {
          // `TextEditor` has no placeholder of its own; this sits where the
          // first line of text will, matching the text container's inset.
          Text("Command or prompt… (⇧↩ for a new line)")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.leading, 5)
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

  private var scheduleRow: some View {
    VStack(alignment: .leading, spacing: 12) {
      DatePicker(
        "Send at",
        selection: $store.scheduledAt.sending(\.scheduledAtChanged),
        displayedComponents: [.date, .hourAndMinute]
      )
      .datePickerStyle(.field)
      HStack(spacing: 8) {
        Toggle("Repeat every", isOn: $store.repeatEnabled.sending(\.repeatEnabledChanged))
        Spacer()
        TextField("Interval", value: $store.repeatAmount.sending(\.repeatAmountChanged), format: .number)
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .frame(width: 52)
          .disabled(!store.repeatEnabled)
        Picker("Unit", selection: $store.repeatUnit.sending(\.repeatUnitChanged)) {
          ForEach(CommandQueueFeature.IntervalUnit.allCases, id: \.self) { unit in
            Text(unit.title).tag(unit)
          }
        }
        .labelsHidden()
        .frame(width: 96)
        .disabled(!store.repeatEnabled)
      }
    }
    .font(.callout)
  }

  /// Send timing, as the small labelled menu a chat composer keeps at its
  /// bottom-right. The inline picker gives the menu its checkmarks.
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
        .font(.callout)
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
        .font(.system(size: 26))
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
