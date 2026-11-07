import CodansCore
import ComposableArchitecture
import SwiftUI

/// Presents `RemoteConnectionSheet` off the sidebar store. Extracted into a
/// `ViewModifier` (applied as a single `.modifier(...)`) so the sidebar's
/// large `body` stays within the Swift type-checker's inference budget — an
/// inline `.sheet` with binding + scope closures pushed it over the limit.
struct RemoteConnectionSheetPresenter: ViewModifier {
  @Bindable var store: StoreOf<HierarchySidebarFeature>

  func body(content: Content) -> some View {
    content.childSheet(
      store.scope(state: \.remoteConnectionSheet, action: \.remoteConnectionSheet),
      onDismiss: { store.send(.remoteConnectionSheet(.cancelButtonTapped)) },
      content: { childStore in
        RemoteConnectionSheet(store: childStore)
          .interactiveDismissDisabled(store.remoteConnectionSheet?.isConnecting ?? false)
      },
    )
  }
}

/// SwiftUI sheet for `RemoteConnectionFeature`, on the shared `FormSheet`
/// frame. With an existing Host, one section holds the Host picker and the
/// path; with "New Host…", the picker, the shared Host field rows, and the
/// path are three sections. The last footer holds the connection error, and
/// "Connecting…" shows in the bottom bar. Auth is delegated to the user's SSH
/// config + agent — the sheet never asks for a password or key.
struct RemoteConnectionSheet: View {
  @Bindable var store: StoreOf<RemoteConnectionFeature>

  var body: some View {
    FormSheet(
      store.isEditing ? "Edit Server Connection" : "Connect to Server",
      primaryTitle: store.isEditing ? "Save" : "Connect",
      canSubmit: store.canConnect,
      canCancel: !store.isConnecting,
      onCancel: { store.send(.cancelButtonTapped) },
      onSubmit: { store.send(.connectButtonTapped) },
      content: {
        if store.isNewHost {
          Section {
            hostPicker
          }
          Section {
            HostFieldsEditor(
              draft: store.newHost,
              isDisabled: store.isConnecting,
              onAddressChanged: { store.send(.addressChanged($0)) },
              onUsernameChanged: { store.send(.usernameChanged($0)) },
              onPortChanged: { store.send(.portChanged($0)) },
              onNameChanged: { store.send(.nameChanged($0)) },
              onIconChanged: { store.send(.iconChanged($0)) }
            )
          } footer: {
            footnote("The new host is added to Settings › Hosts.")
          }
          Section {
            pathField
          } footer: {
            connectionFooter
          }
        } else {
          Section {
            hostPicker
            pathField
          } footer: {
            connectionFooter
          }
        }
      },
      status: {
        if store.isConnecting {
          FormSheetProgress(text: "Connecting…")
        }
      },
    )
  }

  private var pathField: some View {
    TextField(
      "Path",
      text: Binding(
        get: { store.pathDraft },
        set: { store.send(.pathChanged($0)) }
      ),
      prompt: Text(verbatim: "~/project or /srv/app")
    )
    .disabled(store.isConnecting)
  }

  /// The connection error, selectable, above the auth note.
  private var connectionFooter: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = store.errorMessage {
        Text(error)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
      footnote("Authentication uses your SSH config and agent.")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func footnote(_ text: String) -> some View {
    Text(text)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The Host list in its order, then "New Host…".
  private var hostPicker: some View {
    Picker(
      "Host",
      selection: Binding(
        get: { store.hostChoice },
        set: { store.send(.hostChoiceChanged($0)) },
      ),
    ) {
      ForEach(store.hosts) { host in
        Text(Self.pickerTitle(for: host))
          .tag(RemoteConnectionFeature.State.HostChoice.existing(host.id))
      }
      if !store.hosts.isEmpty {
        Divider()
      }
      Text("New Host…")
        .tag(RemoteConnectionFeature.State.HostChoice.newHost)
    }
    .disabled(store.isConnecting)
  }

  /// The display name, plus the address when a Name hides it.
  static func pickerTitle(for host: HostRecord) -> String {
    let authority = host.endpoint.displayAuthority
    return host.displayName == authority ? authority : "\(host.displayName) — \(authority)"
  }
}
