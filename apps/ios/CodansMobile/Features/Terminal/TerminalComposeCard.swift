import SwiftUI

/// A real text editor for what key-by-key typing handles badly: long
/// prompts, input methods, dictation, pasted text. Sends as one pasted
/// block and Enter, or inserts without Enter. Recent entries come back
/// with a swipe up (or the arrows).
struct TerminalComposeCard: View {
  @Binding var draft: String
  let isEnabled: Bool
  let onSend: (_ pressEnter: Bool) -> Void
  let onClose: () -> Void

  @State private var history = ComposeHistoryStore.load()
  /// Position while browsing history; nil while editing a new entry.
  @State private var historyIndex: Int?
  @FocusState private var isFocused: Bool

  private var canSend: Bool {
    isEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        Button("Close", systemImage: "xmark", action: onClose)
          .labelStyle(.iconOnly)
          .accessibilityIdentifier("compose-close")
        Text("Compose")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("Older", systemImage: "chevron.up") { browse(1) }
          .labelStyle(.iconOnly)
          .disabled(history.entries.isEmpty || (historyIndex ?? -1) >= history.entries.count - 1)
        Button("Newer", systemImage: "chevron.down") { browse(-1) }
          .labelStyle(.iconOnly)
          .disabled(historyIndex == nil)
      }
      .font(.body)
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Message to the pane", text: $draft, axis: .vertical)
          .lineLimit(1...6)
          .font(.system(.body, design: .monospaced))
          .textInputAutocapitalization(.sentences)
          .focused($isFocused)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(.fill.tertiary, in: .rect(cornerRadius: 18))
          .accessibilityIdentifier("compose-field")

        Menu {
          Button("Insert Without Enter", systemImage: "text.insert") { submit(pressEnter: false) }
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.background)
            .frame(width: 36, height: 36)
            .background(canSend ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary), in: .circle)
        } primaryAction: {
          submit(pressEnter: true)
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityHint("Touch and hold to insert without Enter")
        .accessibilityIdentifier("compose-send")
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 10)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .gesture(
      DragGesture(minimumDistance: 24).onEnded { value in
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        browse(value.translation.height < 0 ? 1 : -1)
      }
    )
    .onAppear { isFocused = true }
  }

  private func submit(pressEnter: Bool) {
    guard canSend else { return }
    history.record(draft)
    ComposeHistoryStore.save(history)
    historyIndex = nil
    onSend(pressEnter)
  }

  /// Steps through history: +1 older, -1 newer; stepping past the newest
  /// returns to an empty draft.
  private func browse(_ step: Int) {
    let next = (historyIndex ?? -1) + step
    guard next < history.entries.count else { return }
    if next < 0 {
      historyIndex = nil
      draft = ""
    } else {
      historyIndex = next
      draft = history.entries[next]
    }
  }
}

/// Compose history, kept on this device only.
enum ComposeHistoryStore {
  private static let key = "terminal.compose.history.v1"

  static func load() -> ComposeHistory {
    ComposeHistory(entries: UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  static func save(_ history: ComposeHistory) {
    UserDefaults.standard.set(history.entries, forKey: key)
  }
}
