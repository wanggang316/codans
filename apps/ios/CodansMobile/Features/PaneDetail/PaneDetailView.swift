import CodansIPC
import ComposableArchitecture
import SwiftUI

/// Bridges the app store to a pane's own `PaneDetailFeature` store: title,
/// current permission, and a change signal derived from the event stream.
struct PaneDetailContainer: View {
  let store: StoreOf<AppFeature>
  let paneID: String

  var body: some View {
    let location = store.browser.location(ofPane: paneID)
    let agent = store.agents.entries[paneID]
    PaneDetailView(
      paneID: paneID,
      title: location?.paneTitle ?? agent?.title ?? "Pane",
      subtitle: location?.breadcrumb,
      permission: store.connection.permission,
      isConnected: store.connection.status == .connected,
      changeSignal: agent.map { "\($0.state)|\($0.since)|\($0.title ?? "")" } ?? location?.paneTitle ?? ""
    )
    // A new pane gets a fresh feature store instead of inheriting the
    // previous pane's text and draft.
    .id(paneID)
  }
}

struct PaneDetailView: View {
  let title: String
  let subtitle: String?
  let permission: IPC.RemotePermission
  let isConnected: Bool
  let changeSignal: String

  @State private var store: StoreOf<PaneDetailFeature>
  @FocusState private var isInputFocused: Bool

  init(
    paneID: String,
    title: String,
    subtitle: String?,
    permission: IPC.RemotePermission,
    isConnected: Bool,
    changeSignal: String
  ) {
    self.title = title
    self.subtitle = subtitle
    self.permission = permission
    self.isConnected = isConnected
    self.changeSignal = changeSignal
    _store = State(
      initialValue: Store(initialState: PaneDetailFeature.State(paneID: paneID, permission: permission)) {
        PaneDetailFeature()
      })
  }

  var body: some View {
    output
      .navigationTitle(title)
      .navigationSubtitle(subtitle ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh", systemImage: "arrow.clockwise") { store.send(.refresh) }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!isConnected)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if store.showsInput {
          PaneInputBar(store: store, isInputFocused: $isInputFocused, isConnected: isConnected)
        }
      }
      .task(id: isConnected) {
        guard isConnected else { return }
        await store.send(.task).finish()
      }
      .onChange(of: permission) { _, newValue in store.send(.permissionChanged(newValue)) }
      .onChange(of: changeSignal) { _, _ in
        if isConnected { store.send(.paneChanged) }
      }
  }

  @ViewBuilder
  private var output: some View {
    if !store.hasLoaded {
      if let message = store.errorMessage {
        ContentUnavailableView(
          "Couldn't Read Pane", systemImage: "exclamationmark.triangle", description: Text(message))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      ScrollView([.vertical, .horizontal]) {
        Text(store.content)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      // Terminals grow at the bottom; start there and stay there.
      .defaultScrollAnchor(.bottomLeading)
      .overlay(alignment: .top) {
        if let message = store.errorMessage {
          Text(message)
            .font(.footnote)
            .padding(8)
            .background(.regularMaterial, in: .capsule)
            .padding(.top, 8)
        }
      }
    }
  }
}

/// Text field plus a row of named keys. Each key also has a hardware
/// keyboard shortcut for iPad and keyboard-attached phones; the text field
/// owns plain arrows and Tab, so the shortcuts use Control.
private struct PaneInputBar: View {
  @Bindable var store: StoreOf<PaneDetailFeature>
  var isInputFocused: FocusState<Bool>.Binding
  let isConnected: Bool

  var body: some View {
    VStack(spacing: 8) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          key("Esc", .escape, shortcut: KeyboardShortcut(.escape, modifiers: []))
          key("Tab", .tab, shortcut: KeyboardShortcut(.tab, modifiers: .control))
          key("⌃C", .ctrlC, shortcut: KeyboardShortcut("c", modifiers: .control))
          key("↑", .up, shortcut: KeyboardShortcut(.upArrow, modifiers: .control))
          key("↓", .down, shortcut: KeyboardShortcut(.downArrow, modifiers: .control))
          key("Enter", .enter, shortcut: KeyboardShortcut(.return, modifiers: .control))
        }
        .padding(.horizontal)
      }
      HStack(spacing: 8) {
        TextField("Send to pane", text: $store.draft)
          .textFieldStyle(.roundedBorder)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(.system(.body, design: .monospaced))
          .focused(isInputFocused)
          .submitLabel(.send)
          .onSubmit { store.send(.sendTapped) }
        Button("Send", systemImage: "arrow.up.circle.fill") { store.send(.sendTapped) }
          .labelStyle(.iconOnly)
          .font(.title2)
          .disabled(!store.canSend || !isConnected)
      }
      .padding(.horizontal)
    }
    .padding(.vertical, 8)
    .background(.bar)
  }

  private func key(_ title: String, _ key: IPC.TerminalNamedKey, shortcut: KeyboardShortcut) -> some View {
    Button(title) { store.send(.keyTapped(key)) }
      .buttonStyle(.bordered)
      .font(.system(.callout, design: .monospaced))
      .keyboardShortcut(shortcut)
      .disabled(store.isSending || !isConnected)
      .accessibilityLabel(Text("Send \(key.rawValue)"))
  }
}
