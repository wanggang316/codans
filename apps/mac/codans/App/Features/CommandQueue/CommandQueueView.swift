import CodansCore
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

/// Sheet-hosted command composer. Queued commands appear in the pane overlay.
/// Return submits; Shift-Return inserts a line break; Escape closes the sheet.
struct CommandQueueView: View {
  @Bindable var store: StoreOf<CommandQueueFeature>
  /// Sent when Escape lands in the composer. Dismissal is "parent nils the
  /// `@Presents` slot".
  let onDismiss: () -> Void

  @FocusState private var draftFocused: Bool
  @State private var showsScheduleEditor = false
  @State private var showsFilePicker = false
  @State private var showsFileError = false
  @State private var fileError = ""

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
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: Self.width)
    .onAppear { draftFocused = true }
    .onExitCommand(perform: onDismiss)
    .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      switch result {
      case .success(let urls):
        store.send(.filesSelected(urls))
        draftFocused = true
      case .failure(let error):
        fileError = error.localizedDescription
        showsFileError = true
      }
    }
    .alert("Could Not Select Files", isPresented: $showsFileError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(fileError)
    }
  }

  // MARK: - Composer

  /// One box holding the editor and its controls, so the whole thing reads
  /// as a single input the way a chat composer does.
  private var composer: some View {
    VStack(alignment: .leading, spacing: 4) {
      editor
      HStack(spacing: 8) {
        Button {
          showsFilePicker = true
        } label: {
          Image(systemName: "paperclip")
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Insert file paths")
        .accessibilityLabel("Select files")
        Spacer()
        HStack(spacing: 8) {
          if store.mode == .scheduled {
            Button {
              showsScheduleEditor = true
            } label: {
              Text(scheduleSummary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .buttonStyle(.borderless)
            .help(scheduleSummary)
            .accessibilityLabel("Edit schedule: \(scheduleSummary)")
          }
          modeMenu
            // The summary changes width while editing. Anchor to the fixed
            // trailing control so those changes cannot move the popover.
            .popover(isPresented: $showsScheduleEditor, arrowEdge: .bottom) {
              scheduleEditor
            }
        }
        .onChange(of: store.mode) { _, mode in
          showsScheduleEditor = mode == .scheduled
        }
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

  private var scheduleSummary: String {
    CommandQueueStyle.description(of: .scheduled(at: store.scheduledAt, repeatEvery: store.repeatInterval))
  }

  private var scheduleEditor: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Schedule message")
        .font(.headline)
      DatePicker(
        "Send at",
        selection: $store.scheduledAt.sending(\.scheduledAtChanged),
        displayedComponents: [.date, .hourAndMinute]
      )
      .datePickerStyle(.field)
      HStack(spacing: 8) {
        Toggle("Repeat", isOn: $store.repeatEnabled.sending(\.repeatEnabledChanged))
          .toggleStyle(.checkbox)
          .fixedSize()
        if store.repeatEnabled {
          TextField("Interval", value: $store.repeatAmount.sending(\.repeatAmountChanged), format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
          Picker("Unit", selection: $store.repeatUnit.sending(\.repeatUnitChanged)) {
            ForEach(CommandQueueFeature.IntervalUnit.allCases, id: \.self) { unit in
              Text(unit.title).tag(unit)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        }
        Spacer(minLength: 0)
      }
      .frame(height: 28)
      HStack {
        Spacer()
        Button("Done") {
          showsScheduleEditor = false
          draftFocused = true
        }
        .keyboardShortcut(.defaultAction)
      }
      .frame(height: 28)
    }
    .padding(20)
    // Keep the native popover size stable when repeat controls appear.
    .frame(width: 340, height: 208)
    .onExitCommand { showsScheduleEditor = false }
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
    .disabled(!store.canSubmit || showsScheduleEditor)
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
